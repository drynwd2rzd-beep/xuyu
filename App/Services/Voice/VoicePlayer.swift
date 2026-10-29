import SwiftUI
import AVFoundation
import Observation

/// 播放语音消息：同一时间只放一条，放下一条时上一条自动停
@MainActor
@Observable
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()

    /// 正在放的是哪条（语音消息的 id，或试听的声音 id）
    private(set) var playing: String?
    /// 播放进度 0～1
    private(set) var progress: Double = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var durations: [String: TimeInterval] = [:]

    /// 返回 false：这段声音放不出来（文件坏了、格式不对）
    @discardableResult
    func toggle(_ id: String, data: Data) -> Bool {
        if playing == id { stop(); return true }
        halt()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let player = try? AVAudioPlayer(data: data), player.play() else { return false }
        player.delegate = self
        self.player = player
        playing = id
        progress = 0
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let p = self.player, p.duration > 0 else { continue }
                self.progress = p.currentTime / p.duration
            }
        }
        return true
    }

    /// 停下，并把声音还给别的 App：你在听的音乐接着放（以前播完一直占着，音乐停了就不回来）
    func stop() {
        let wasPlaying = player != nil
        halt()
        guard wasPlaying else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 只停下这一条；马上要放下一条时用，中间不把声音还回去，音乐不会突然响一下又停
    private func halt() {
        ticker?.cancel()
        player?.stop()
        player = nil
        withAnimation(Motion.snappy) {
            playing = nil
            progress = 0
        }
    }

    /// 语音有多长（算一次记下来）
    func duration(_ id: String, data: Data) -> TimeInterval {
        if let known = durations[id] { return known }
        let seconds = (try? AVAudioPlayer(data: data))?.duration ?? 0
        durations[id] = seconds
        return seconds
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
