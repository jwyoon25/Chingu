import AVFoundation
import Combine
import Foundation

/// Orchestrates the voice loop and owns all speech-related state, wrapping the existing
/// chat pipeline **without editing it**. This is CP4's home for the two seams reserved on
/// `main` (see `docs/CP4-SPEC.md` §6.3 / §6.5):
///
///   • **in**  — `model.submit(text: transcript)` (the exact path a typed question uses)
///   • **out** — streaming TTS via `onAssistantTextUpdate` + a final flush on
///               `onAssistantResponseComplete`
///
/// Both are already `public` on `ChatViewModel`, so this controller drives them from the
/// outside — `ChatViewModel.swift` is only extended with the streaming hook, not reshaped.
@MainActor
final class VoiceController: NSObject, ObservableObject {

    enum State: Equatable { case idle, listening, transcribing, speaking }

    @Published private(set) var state: State = .idle
    /// Surfaced as a banner in `ChatView` (mic denied, no key, STT/TTS failure). Errors
    /// are UI state, not chat bubbles — appending a bubble would require editing the VM.
    @Published var errorMessage: String?

    private let model: ChatViewModel
    private let speech = SpeechService()
    private let mic = MicCapture()
    private var player: AVAudioPlayer?       // retained, or playback is cut off mid-clip
    private var listenTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // Streaming TTS — synthesize and queue chunks as the reply streams in.
    private var speechGeneration = 0
    private var spokenUpTo = 0                 // index into `streamingSpeakable`
    private var streamingSpeakable = ""
    private var pendingAudio: [Data] = []
    private var isDequeuing = false

    init(model: ChatViewModel) {
        self.model = model
        super.init()
        // OUTPUT SEAM — stream speech while tokens arrive; flush any tail on `.done`.
        model.onAssistantTextUpdate = { [weak self] partial in
            self?.feedStreamingText(partial)
        }
        model.onAssistantResponseComplete = { [weak self] reply in
            self?.finishStreamingSpeech(reply)
        }

        // ⌃⌥⌘K posts this — start (or barge into) a voice turn.
        NotificationCenter.default.publisher(for: .chinguActivateVoice)
            .sink { [weak self] _ in Task { @MainActor in self?.activateVoice() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .chinguDeactivateVoice)
            .sink { [weak self] _ in Task { @MainActor in self?.deactivateVoice() } }
            .store(in: &cancellables)

        // A new assistant turn (typed or voice) — stop any leftover speech from the prior reply.
        model.$isResponding
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.beginAssistantTurn() }
            .store(in: &cancellables)
    }

    // MARK: Hotkey-driven voice activation

    /// Start a voice turn from ⌃⌥⌘K. Barge in on a spoken reply; no-op mid-transcription.
    func activateVoice() {
        switch state {
        case .idle:
            guard !model.isResponding else { return }
            startListening()
        case .speaking:
            interruptSpeech()
            startListening()
        case .listening, .transcribing:
            break
        }
    }

    /// Chingu was dismissed — stop playback and cancel an in-progress capture.
    func deactivateVoice() {
        interruptSpeech()
        if state == .listening || state == .transcribing { cancelListening() }
    }

    /// Stop any in-flight TTS (and clear the chunk queue). Callable from the UI stop button.
    func interruptSpeech() {
        speechGeneration += 1
        pendingAudio.removeAll()
        isDequeuing = false
        spokenUpTo = 0
        streamingSpeakable = ""
        player?.stop()
        player = nil
        if state == .speaking { state = .idle }
    }

    private func cancelListening() {
        listenTask?.cancel()
        listenTask = nil
        state = .idle
    }

    // MARK: Mic button

    /// Circle button: start/stop listening, or interrupt speech and listen again.
    func toggleMic() {
        switch state {
        case .listening:
            mic.requestStop()
        case .speaking:
            interruptSpeech()
            startListening()
        case .transcribing:
            break
        case .idle:
            guard !model.isResponding else { return }
            startListening()
        }
    }

    // MARK: Listen → transcribe → submit (input seam)

    private func startListening() {
        errorMessage = nil
        state = .listening
        listenTask = Task {
            do {
                let audio = try await mic.recordUntilSilence()
                state = .transcribing
                let transcript = try await speech.transcribe(
                    audio, filename: MicCapture.filename, mimeType: MicCapture.mimeType)
                state = .idle
                resetStreamingForNewTurn()
                model.submit(text: transcript)
            } catch is CancellationError {
                state = .idle
            } catch {
                present(error)
                state = .idle
            }
        }
    }

    // MARK: Streaming speak (output seam)

    private func resetStreamingForNewTurn() {
        beginAssistantTurn()
    }

    private func beginAssistantTurn() {
        speechGeneration += 1
        spokenUpTo = 0
        streamingSpeakable = ""
        pendingAudio.removeAll()
        isDequeuing = false
        player?.stop()
        player = nil
        if state == .speaking { state = .idle }
    }

    private func feedStreamingText(_ raw: String) {
        let stripped = PointTag.strippingTrailingTag(raw)
        let speakable = SpeechService.plainSpeech(stripped)
        guard speakable != streamingSpeakable else { return }
        streamingSpeakable = speakable
        enqueueReadyChunks()
    }

    private func finishStreamingSpeech(_ finalText: String) {
        let stripped = PointTag.strippingTrailingTag(finalText)
        let speakable = SpeechService.plainSpeech(stripped)
        streamingSpeakable = speakable
        // Speak anything left unsynthesized (including short replies that never hit a chunk boundary).
        let tail = String(speakable.dropFirst(spokenUpTo)).trimmingCharacters(in: .whitespacesAndNewlines)
        spokenUpTo = speakable.count
        guard !tail.isEmpty else { return }
        synthesizeAndEnqueue(tail)
    }

    /// Pull speakable chunks off the front of the unsynthesized tail whenever we hit a
    /// sentence boundary (or a word boundary after enough characters).
    private func enqueueReadyChunks() {
        while let chunk = nextChunk() {
            synthesizeAndEnqueue(chunk)
        }
    }

    private func nextChunk() -> String? {
        guard spokenUpTo < streamingSpeakable.count else { return nil }
        let tail = String(streamingSpeakable.dropFirst(spokenUpTo))
        guard !tail.isEmpty else { return nil }

        // Sentence end — start speaking as soon as we have a complete phrase.
        if let end = tail.firstIndex(where: { ".!?".contains($0) }) {
            let after = tail.index(after: end)
            let chunk = String(tail[..<after]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard chunk.count >= 8 else { return nil }
            spokenUpTo += tail.distance(from: tail.startIndex, to: after)
            return chunk
        }

        // No sentence yet — after ~35 chars, break at the last space so we don't wait forever.
        if tail.count >= 35, let space = tail.prefix(50).lastIndex(of: " ") {
            let chunk = String(tail[..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty else { return nil }
            spokenUpTo += tail.distance(from: tail.startIndex, to: space) + 1
            return chunk
        }

        return nil
    }

    private func synthesizeAndEnqueue(_ text: String) {
        let generation = speechGeneration
        Task {
            do {
                let audio = try await speech.synthesize(text)
                guard generation == speechGeneration else { return }
                pendingAudio.append(audio)
                playNextInQueue()
            } catch {
                guard generation == speechGeneration else { return }
                present(error)
            }
        }
    }

    private func playNextInQueue() {
        guard !isDequeuing, player == nil || !(player?.isPlaying ?? false) else { return }
        guard !pendingAudio.isEmpty else {
            if state == .speaking { state = .idle }
            return
        }
        isDequeuing = true
        let data = pendingAudio.removeFirst()
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            self.player = player
            state = .speaking
            player.play()
        } catch {
            present(error)
            isDequeuing = false
            playNextInQueue()
        }
        isDequeuing = false
    }

    // MARK: Helpers

    private func present(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = message
        NSLog("Chingu CP4: \(message)")
    }
}

extension VoiceController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            if self.pendingAudio.isEmpty {
                if self.state == .speaking { self.state = .idle }
            } else {
                self.playNextInQueue()
            }
        }
    }
}

extension Notification.Name {
    /// Posted when ⌃⌥⌘K is pressed — start (or barge into) a voice turn.
    static let chinguActivateVoice = Notification.Name("chingu.activateVoice")
    /// Posted when Chingu is hidden — stop listening/playback.
    static let chinguDeactivateVoice = Notification.Name("chingu.deactivateVoice")
}
