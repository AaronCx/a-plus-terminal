import AVFoundation
import Speech
import Observation

/// On-device push-to-talk dictation (§4.4). `requiresOnDeviceRecognition` is
/// a hard requirement — if the on-device model is unavailable for the locale
/// this errors out; it never falls back to server recognition.
@MainActor
@Observable
final class DictationEngine {
    enum State: Equatable {
        case idle
        case listening
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var transcript = ""
    /// True once the recognizer delivers a final (non-partial) result.
    private(set) var isFinal = false

    // The input level is written from the real-time audio tap (a non-main
    // thread) and read by the waveform ~30×/s. A lock keeps it ordered and
    // cheap; the previous `Task { @MainActor … }` per buffer could deliver
    // levels out of order and piled up unbounded tasks during teardown.
    private let levelLock = NSLock()
    nonisolated(unsafe) private var _audioLevel: Float = 0
    /// 0…1 input level for the waveform display.
    nonisolated var audioLevel: Float { levelLock.withLock { _audioLevel } }

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Set when we deliberately end audio / stop, so the recognizer's expected
    /// post-stop cancellation error isn't surfaced as a failure.
    private var intentionallyStopped = false

    func start() async {
        guard state != .listening else { return }
        transcript = ""
        isFinal = false
        intentionallyStopped = false

        let speechAuth = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechAuth == .authorized else {
            state = .failed("Speech recognition permission was denied. Enable it in Settings → a+Terminal.")
            return
        }
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            state = .failed("Microphone permission was denied. Enable it in Settings → a+Terminal.")
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            state = .failed("Speech recognition isn't available for your language.")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // Never fall back to network recognition — zero-data posture.
            state = .failed("On-device dictation isn't available for your language on this iPhone. a+Terminal never sends audio to a server, so dictation is disabled.")
            return
        }

        let request = Self.makeRecognitionRequest()
        self.request = request

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                self?.storeLevel(Self.level(of: buffer))
            }
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            stop()
            state = .failed("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }

        state = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal { self.isFinal = true }
                }
                if let error, !self.intentionallyStopped {
                    // A genuine recognition error mid-listening. The expected
                    // cancellation after a deliberate stop is gated out above.
                    self.state = .failed(error.localizedDescription)
                    self.stopAudio()
                }
            }
        }
    }

    /// Builds the recognition request with the zero-data flags locked on.
    /// Factored out so a unit test can assert the on-device requirement holds.
    nonisolated static func makeRecognitionRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        return request
    }

    /// For auto-send: stop feeding audio so the recognizer emits a *final*
    /// result, wait briefly for it, then return that — falling back to the
    /// latest partial. Avoids transmitting a partial the recognizer revises.
    func finishForAutoSend() async -> String {
        guard state == .listening else { return transcript }
        endAudioInput()
        for _ in 0..<15 where !isFinal {   // up to ~1.5s
            try? await Task.sleep(for: .milliseconds(100))
        }
        return transcript
    }

    func stop() {
        intentionallyStopped = true
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        if state == .listening {
            state = .idle
        }
    }

    /// Stop capturing/feeding audio so the recognizer can finalize, *without*
    /// cancelling the recognition task or deactivating the session (the final
    /// result still needs to arrive).
    private func endAudioInput() {
        intentionallyStopped = true
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        levelLock.withLock { _audioLevel = 0 }
    }

    private func stopAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        levelLock.withLock { _audioLevel = 0 }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated private func storeLevel(_ value: Float) {
        levelLock.withLock { _audioLevel = value }
    }

    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<frames {
            let sample = channelData[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))
        return min(1, rms * 18)
    }
}
