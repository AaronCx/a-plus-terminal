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
    /// 0…1 input level for the waveform display.
    private(set) var audioLevel: Float = 0

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() async {
        guard state != .listening else { return }
        transcript = ""

        let speechAuth = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechAuth == .authorized else {
            state = .failed("Speech recognition permission was denied. Enable it in Settings → a-Terminal.")
            return
        }
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            state = .failed("Microphone permission was denied. Enable it in Settings → a-Terminal.")
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            state = .failed("Speech recognition isn't available for your language.")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // Never fall back to network recognition — zero-data posture.
            state = .failed("On-device dictation isn't available for your language on this iPhone. a-Terminal never sends audio to a server, so dictation is disabled.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                let level = Self.level(of: buffer)
                Task { @MainActor [weak self] in
                    self?.audioLevel = level
                }
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
                }
                if let error, self.state == .listening {
                    // Cancellation after stop() is expected; surface real errors.
                    self.state = .failed(error.localizedDescription)
                    self.stopAudio()
                }
            }
        }
    }

    func stop() {
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        if state == .listening {
            state = .idle
        }
    }

    private func stopAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        audioLevel = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
