import Foundation
import Speech
import AVFoundation
import Observation

/// 语音输入：说话实时转成文字
@MainActor
@Observable
final class Dictation {
    private(set) var isRecording = false
    private(set) var level: Float = 0
    var onText: ((String) -> Void)?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    @ObservationIgnored private let audio = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    func toggle() async -> String? {
        if isRecording {
            stop()
            return nil
        }
        return await start()
    }

    /// 返回错误提示；成功时返回 nil
    func start() async -> String? {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else { return "需要在系统设置里允许「语音识别」。" }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { return "需要在系统设置里允许使用麦克风。" }
        guard let recognizer, recognizer.isAvailable else { return "语音识别暂时不可用。" }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request
            let input = audio.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                let level = Self.rms(buffer)
                Task { @MainActor in self?.level = level }
            }
            audio.prepare()
            try audio.start()
            isRecording = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.onText?(result.bestTranscription.formattedString) }
                    if error != nil || result?.isFinal == true { self.stop() }
                }
            }
            return nil
        } catch {
            stop()
            return "无法开始录音：\(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRecording || task != nil else { return }
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return min(1, sqrt(sum / Float(n)) * 8)
    }
}
