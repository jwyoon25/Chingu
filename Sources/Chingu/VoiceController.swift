import AVFoundation
import Combine
import Foundation

/// Orchestrates the voice loop and owns all speech-related state, wrapping the existing
/// chat pipeline **without editing it**. This is CP4's home for the two seams reserved on
/// `main` (see `docs/CP4-SPEC.md` §6.3 / §6.5):
///
///   • **in**  — `model.submit(text: transcript)` (the exact path a typed question uses)
///   • **out** — `model.onAssistantResponseComplete = { speak($0) }` (text-to-speech)
///
/// Both are already `public` on `ChatViewModel`, so this controller drives them from the
/// outside — `ChatViewModel.swift` is never edited. ElevenLabs does voice only; all
/// reasoning/vision/search stays with Claude, untouched.
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

    init(model: ChatViewModel) {
        self.model = model
        super.init()
        // OUTPUT SEAM — speak each completed reply aloud. The VM already invokes this hook
        // with the final assistant text; we only set the closure (no VM edit).
        model.onAssistantResponseComplete = { [weak self] reply in
            Task { await self?.speak(reply) }
        }

        // The global hotkey (⌃⌥⌘K) posts these when Chingu is shown/hidden, so summoning
        // the overlay also starts listening hands-free (and dismissing it stops voice).
        NotificationCenter.default.publisher(for: .chinguActivateVoice)
            .sink { [weak self] _ in Task { @MainActor in self?.activateVoice() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .chinguDeactivateVoice)
            .sink { [weak self] _ in Task { @MainActor in self?.deactivateVoice() } }
            .store(in: &cancellables)
    }

    // MARK: Hotkey-driven voice activation

    /// Start a voice turn from the global hotkey. Mirrors a mic tap but biased to *start*:
    /// barge in on a spoken reply, no-op if already capturing or a turn is in flight.
    func activateVoice() {
        switch state {
        case .idle:
            guard !model.isResponding else { return }
            startListening()
        case .speaking:
            stopSpeaking()
            startListening()
        case .listening, .transcribing:
            break
        }
    }

    /// Chingu was dismissed — stop playback and cancel an in-progress capture so the mic
    /// isn't left listening behind a hidden panel.
    func deactivateVoice() {
        stopSpeaking()
        if state == .listening || state == .transcribing { cancelListening() }
    }

    private func cancelListening() {
        listenTask?.cancel()
        listenTask = nil
        state = .idle
    }

    // MARK: Mic button

    /// Single mic-button action; behaviour depends on the current state (barge-in aware).
    func toggleMic() {
        switch state {
        case .listening:
            mic.requestStop()                      // finish early; the task transcribes
        case .speaking:
            stopSpeaking()                         // barge-in: cut TTS…
            startListening()                       // …and listen again
        case .transcribing:
            break                                  // ignore taps mid-transcription
        case .idle:
            guard !model.isResponding else { return }   // one turn at a time
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
                // INPUT SEAM — identical to a typed question (no VM edit).
                model.submit(text: transcript)
            } catch is CancellationError {
                state = .idle
            } catch {
                present(error)
                state = .idle
            }
        }
    }

    // MARK: Speak (output seam)

    private func speak(_ reply: String) async {
        do {
            let audio = try await speech.synthesize(reply)
            let player = try AVAudioPlayer(data: audio)
            player.delegate = self
            self.player = player
            state = .speaking
            player.play()
        } catch {
            present(error)
            if state == .speaking { state = .idle }
        }
    }

    private func stopSpeaking() {
        player?.stop()
        player = nil
        if state == .speaking { state = .idle }
    }

    // MARK: Helpers

    private func present(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = message
        NSLog("Chingu CP4: \(message)")
    }
}

extension VoiceController: AVAudioPlayerDelegate {
    /// Delegate callbacks may arrive off the main thread; hop back to update state.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            if self.state == .speaking { self.state = .idle }
        }
    }
}

extension Notification.Name {
    /// Posted when Chingu is shown via the global hotkey — start listening hands-free.
    static let chinguActivateVoice = Notification.Name("chingu.activateVoice")
    /// Posted when Chingu is hidden via the global hotkey — stop listening/playback.
    static let chinguDeactivateVoice = Notification.Name("chingu.deactivateVoice")
}
