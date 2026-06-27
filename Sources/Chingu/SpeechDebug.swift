import AVFoundation
import Foundation

/// **TEMPORARY** de-risking harness for CP4 (see `docs/CP4-SPEC.md` §5). It lets us
/// validate the ElevenLabs TTS/STT round-trips inside the running app *before* the real
/// mic UI and `VoiceController` exist — so the network/audio plumbing is proven with
/// near-zero merge risk.
///
/// **Delete this file and its temporary button in `ChatView` once the seams are wired
/// (build-order step 6).** Nothing in shipping CP4 depends on it.
@MainActor
final class SpeechDebug: ObservableObject {
    /// Human-readable result of the last test (shown under the composer, also `NSLog`ged).
    @Published var status: String = ""
    /// Drives the record button's start/stop label.
    @Published var isRecording: Bool = false

    private let speech = SpeechService()
    private let mic = MicCapture()
    private var player: AVAudioPlayer?   // retained — or playback is cut off mid-clip

    /// Step 2: hardcoded string → ElevenLabs TTS → `AVAudioPlayer` → you hear it.
    func testTTS() {
        status = "Synthesizing…"
        Task {
            do {
                let audio = try await speech.synthesize(
                    "안녕하세요, 친구! This is Chingu's text-to-speech test.")
                player = try AVAudioPlayer(data: audio)
                player?.play()
                status = "Playing \(audio.count) bytes ✓"
                NSLog("Chingu CP4: TTS test OK (\(audio.count) bytes)")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                status = "TTS failed: \(message)"
                NSLog("Chingu CP4: TTS test failed — \(message)")
            }
        }
    }

    /// Step 4: tap to listen (first tap triggers the mic permission prompt). It records
    /// until you stop talking (auto-stop on silence), then transcribes and shows the
    /// result. Tap again to stop early.
    func toggleRecord() {
        if isRecording {
            mic.requestStop()       // end early; the listening Task finishes & transcribes
            return
        }

        isRecording = true
        status = "Listening… speak, then pause"
        Task {
            do {
                let audio = try await mic.recordUntilSilence(onSpeechStart: { [weak self] in
                    self?.status = "Listening…"
                })
                isRecording = false
                status = "Transcribing \(audio.count) bytes…"
                let transcript = try await speech.transcribe(
                    audio, filename: MicCapture.filename, mimeType: MicCapture.mimeType)
                status = "Heard: \u{201C}\(transcript)\u{201D}"
                NSLog("Chingu CP4: STT OK — \(transcript)")
            } catch {
                isRecording = false
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                status = "Listen failed: \(message)"
                NSLog("Chingu CP4: listen/STT failed — \(message)")
            }
        }
    }
}
