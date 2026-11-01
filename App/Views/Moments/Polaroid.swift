import SwiftUI
import UIKit

/// 一张拍立得：白边、圆角、微微倾斜；影子只在底板上
struct Polaroid: View {
    let photo: AlbumPhoto?
    var width: CGFloat
    var height: CGFloat
    var tilt: Double = 0
    var border: CGFloat = 5

    var body: some View {
        Group {
            if let photo, let image = cachedImage(photo.data, key: photo.id.uuidString) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Palette.fill
            }
        }
        .frame(width: width - border * 2, height: height - border * 2)
        .clipShape(RoundedRectangle(cornerRadius: max(4, Radius.tile - border), style: .continuous))
        .padding(border)
        .background {
            RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.13), radius: 12, y: 8)
        }
        .rotationEffect(.degrees(tilt))
    }
}

/// 动态里的配图：一张就大一点、微微歪着；几张就错开叠在一起
struct PolaroidStack: View {
    let photos: [AlbumPhoto]

    var body: some View {
        if photos.count == 1 {
            Polaroid(photo: photos[0], width: 236, height: 220, tilt: -1.5)
                .padding(.vertical, 6)
                .padding(.leading, 4)
        } else {
            ZStack(alignment: .topLeading) {
                ForEach(Array(photos.prefix(3).enumerated()), id: \.element.id) { i, p in
                    Polaroid(photo: p, width: 172, height: 184, tilt: [-3, 4, -1][i])
                        .offset(x: CGFloat(i) * 104, y: CGFloat(i % 2) * 22)
                }
            }
            .frame(height: 214, alignment: .topLeading)
            .padding(.vertical, 4)
            .padding(.leading, 4)
        }
    }
}

/// 语音动态：点一下播放，波形跟着走
struct VoiceMomentButton: View {
    let moment: Moment
    private var player: VoicePlayer { VoicePlayer.shared }

    var body: some View {
        let id = "moment-\(moment.id)"
        let playing = player.playing == id
        let data = moment.voice ?? Data()
        Button { player.toggle(id, data: data) } label: {
            HStack(spacing: Space.item) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.inkInverse)
                    .frame(width: 34, height: 34)
                    .background(Palette.ink, in: Circle())
                Waveform(seed: id, bars: 16, progress: playing ? player.progress : 0)
                Text(Self.length(player.duration(id, data: data)))
                    .font(.system(size: Typo.secondary).monospacedDigit())
                    .foregroundStyle(Palette.inkSoft)
            }
            .padding(.leading, 6)
            .padding(.trailing, Space.card)
            .frame(height: 46)
            .background(Palette.paper, in: Capsule())
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel(playing ? "暂停语音" : "播放语音")
    }

    /// 语音时长，形如 0:07（不足一秒算一秒）
    static func length(_ seconds: TimeInterval) -> String {
        let s = max(1, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
