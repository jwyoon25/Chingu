import AVFoundation
import Foundation

/// Captures microphone audio to a temporary `.m4a` (AAC, 16 kHz mono — small and accepted
/// by ElevenLabs STT) and hands the finished clip back as `Data`. Pure capture: it knows
/// nothing about ElevenLabs or Claude.
///
/// **No `AVAudioSession`** — that's iOS-only; on macOS `AVAudioRecorder` needs none.
/// Microphone permission is requested lazily on first use; it relies on the embedded
/// `NSMicrophoneUsageDescription` (see `docs/CP4-SPEC.md` §4) or the first request crashes.
/// Silence/endpoint auto-stop is layered on in step 4 — this step is manual start/stop.
@MainActor
final class MicCapture {

    enum MicError: LocalizedError {
        case permissionDenied
        case recorderUnavailable(String)
        case noAudioCaptured
        case silence

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access denied. Enable it in System Settings ▸ Privacy & "
                     + "Security ▸ Microphone, then relaunch."
            case let .recorderUnavailable(message):
                return "Couldn't start recording: \(message)"
            case .noAudioCaptured:
                return "No audio was captured."
            case .silence:
                return "Didn't hear anything — tap and speak."
            }
        }
    }

    /// File parts for the STT multipart upload.
    static let filename = "audio.m4a"
    static let mimeType = "audio/mp4"

    /// AAC in an `.m4a` container, 16 kHz mono — small and STT-friendly.
    private static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var stopRequested = false

    var isRecording: Bool { recorder?.isRecording ?? false }

    /// Requests mic permission (lazily). Returns `true` if access is granted. Uses
    /// `AVCaptureDevice` (the canonical macOS path) — this is what triggers the TCC prompt
    /// that needs the embedded usage description.
    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// Starts recording to a fresh temp file. Throws on denied permission or a recorder
    /// failure (never crashes).
    func start() async throws {
        guard await requestPermission() else { throw MicError.permissionDenied }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chingu-\(UUID().uuidString).m4a")
        do {
            let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
            recorder.isMeteringEnabled = true     // for level UI + step-4 endpointing
            guard recorder.record() else {
                throw MicError.recorderUnavailable("AVAudioRecorder.record() returned false")
            }
            self.recorder = recorder
            self.fileURL = url
        } catch let error as MicError {
            throw error
        } catch {
            throw MicError.recorderUnavailable(error.localizedDescription)
        }
    }

    /// Current input level in dBFS (~ −160…0). Refreshes the meter first. Used by the
    /// listening UI and by step-4 silence endpointing.
    func currentLevel() -> Float {
        guard let recorder else { return -160 }
        recorder.updateMeters()
        return recorder.averagePower(forChannel: 0)
    }

    /// Records until the speaker finishes — detected by silence — then returns the audio.
    ///
    /// Endpointing: it waits for **speech onset** (level first rising above
    /// `silenceThreshold`) before arming the silence timer, so leading silence doesn't end
    /// the utterance instantly. Once speech has started, a continuous `silenceDuration` of
    /// quiet ends it. `onsetTimeout` bounds the initial wait (no speech → `.silence`);
    /// `maxDuration` caps a run-on. Defaults lean toward **not cutting the speaker off**.
    /// A call to `requestStop()` (e.g. a second tap) ends it early and returns what we have.
    func recordUntilSilence(
        silenceThreshold: Float = -40,
        silenceDuration: TimeInterval = 0.7,
        onsetTimeout: TimeInterval = 6,
        maxDuration: TimeInterval = 30,
        onSpeechStart: (@MainActor () -> Void)? = nil
    ) async throws -> Data {
        try await start()
        stopRequested = false

        let poll: TimeInterval = 0.05
        var elapsed: TimeInterval = 0
        var silentFor: TimeInterval = 0
        var speechStarted = false

        while true {
            try? await Task.sleep(nanoseconds: 50_000_000)   // ~50 ms
            if stopRequested { break }

            elapsed += poll
            let level = currentLevel()

            if level > silenceThreshold {
                if !speechStarted {
                    speechStarted = true
                    onSpeechStart?()
                }
                silentFor = 0
            } else if speechStarted {
                silentFor += poll
                if silentFor >= silenceDuration { break }
            }

            if !speechStarted, elapsed >= onsetTimeout {
                _ = try? stop()
                throw MicError.silence
            }
            if elapsed >= maxDuration { break }
        }

        return try stop()
    }

    /// Ends an in-progress `recordUntilSilence` early (e.g. a manual stop tap).
    func requestStop() { stopRequested = true }

    /// Stops recording and returns the captured audio bytes, cleaning up the temp file.
    @discardableResult
    func stop() throws -> Data {
        guard let recorder, let url = fileURL else { throw MicError.noAudioCaptured }
        recorder.stop()
        self.recorder = nil
        self.fileURL = nil

        let data = (try? Data(contentsOf: url)) ?? Data()
        try? FileManager.default.removeItem(at: url)
        guard !data.isEmpty else { throw MicError.noAudioCaptured }
        return data
    }
}
