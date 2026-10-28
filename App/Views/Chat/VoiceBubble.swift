import SwiftUI

/// 语音消息：点一下播放 / 暂停。波形随播放从左到右变深，右边是时长；
/// 长按「转文字」后，下面淡淡地显示说的话。语音越长，气泡越宽（像微信）
struct VoiceBubble: View {
    let id: String
    let data: Data
    let time: String
    var transcript: String?

    private var player: VoicePlayer { VoicePlayer.shared }
    private var isPlaying: Bool { player.playing == id }

    var body: some View {
        let seconds = player.duration(id, data: data)
        VStack(alignment: .leading, spacing: 8) {
            Button { player.toggle(id, data: data) } label: {
                HStack(spacing: 10) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.inkInverse)
                        .frame(width: 28, height: 28)
                        .background(Palette.ink, in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                    Waveform(seed: id, bars: Self.bars(for: seconds), progress: isPlaying ? player.progress : 0)
                        .frame(height: 22)
                    Text(Self.length(seconds))
                        .font(TimedText.stampFont)
                        .foregroundStyle(TimedText.stampColor)
                    Text(time)
                        .font(TimedText.stampFont)
                        .foregroundStyle(TimedText.stampColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "暂停语音" : "播放语音")
            if let transcript {
                Text(transcript)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.reveal)
            }
        }
        .animation(Motion.snappy, value: isPlaying)
    }

    /// 语音越长波形越多（7～26 根），气泡跟着变宽
    static func bars(for seconds: TimeInterval) -> Int {
        min(26, max(7, 6 + Int(seconds.rounded())))
    }

    static func length(_ seconds: TimeInterval) -> String {
        "\(max(1, Int(seconds.rounded())))″"
    }
}

/// 一排高低不一的小竖条：每条语音的样子固定（按 id 算出来），播放过的部分颜色变深
struct Waveform: View {
    let seed: String
    let bars: Int
    let progress: Double

    var body: some View {
        let heights = Self.heights(seed: seed, count: bars)
        HStack(spacing: 2.5) {
            ForEach(0..<bars, id: \.self) { i in
                let played = progress > 0 && Double(i) / Double(bars) <= progress
                Capsule()
                    .fill(played ? Palette.ink : Palette.inkSoft.opacity(0.45))
                    .frame(width: 2.5, height: 4 + 18 * heights[i])
            }
        }
        .animation(.linear(duration: 0.05), value: progress)
    }

    /// 由 id 算出一组稳定的高度：中间高、两头低，看起来像说话的起伏
    static func heights(seed: String, count: Int) -> [CGFloat] {
        // FNV 哈希：每次打开 App 都一样（系统自带的 hashValue 每次启动都会变）
        var state: UInt64 = seed.utf8.reduce(14695981039346656037) { ($0 ^ UInt64($1)) &* 1099511628211 } | 1
        return (0..<count).map { i in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = CGFloat((state >> 33) % 1000) / 1000
            let middle = 1 - abs(CGFloat(i) / CGFloat(max(1, count - 1)) - 0.5) * 1.2
            return max(0.12, min(1, 0.35 * middle + 0.65 * noise))
        }
    }
}
