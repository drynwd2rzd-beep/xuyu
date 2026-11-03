import SwiftUI

/// 画册的一起听：黑底，正在一起听的那首（没在听就是上次听的那首）。
/// 正在听时有进度和上一首 / 暂停 / 下一首；没在听只是一页回忆，要接着听去聊天里点「一起听」
struct ListenPage: View {
    let song: ListenTogether.Song
    let number: Int
    let total: Int
    private var music: ListenTogether { .shared }
    /// 黑底上那团很淡的白光有多大、三个按钮隔多远（照设计稿）
    private static let glowRadius: CGFloat = 320
    private static let controlGap: CGFloat = 44

    var body: some View {
        PhotobookPage(folio: String(localized: "一起听"), number: number, total: total, onDark: true) {
            Palette.listenNight
            RadialGradient(colors: [Palette.onPhoto.opacity(0.14), .clear], center: UnitPoint(x: 0.5, y: 0.34),
                           startRadius: 0, endRadius: Self.glowRadius)
        } content: {
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(music.isOn ? "正在一起听" : "上次一起听的")
                    .font(.system(size: Typo.caption))
                    .tracking(Typo.labelTracking)
                    .foregroundStyle(Palette.onPhoto.opacity(0.5))
                    .reveal()
                Text(verbatim: song.title)
                    .font(.system(size: Typo.Book.song, weight: .light))
                    .tracking(Typo.tracking)
                    .foregroundStyle(Palette.onPhoto)
                    .lineLimit(2)
                    .reveal()
                Text(verbatim: song.artist)
                    .font(Typo.serif(Typo.label))
                    .tracking(Typo.tracking)
                    .foregroundStyle(Palette.onPhoto.opacity(0.55))
                    .reveal(1)
                if music.isOn {
                    progress.padding(.top, Space.page).reveal(2)
                    controls.padding(.top, Space.item).reveal(2)
                }
            }
        }
    }

    private var progress: some View {
        let fraction = music.duration > 0 ? min(1, music.position / music.duration) : 0
        return VStack(spacing: Space.tight) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.onPhoto.opacity(0.18))
                    Capsule().fill(Palette.onPhoto).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 1)
            HStack {
                Text(verbatim: CallLogs.clock(music.position))
                Spacer()
                Text(verbatim: CallLogs.clock(music.duration))
            }
            .font(Typo.serif(Typo.label))
            .monospacedDigit()
            .foregroundStyle(Palette.onPhoto.opacity(0.45))
        }
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: Self.controlGap) {
            Spacer()
            ghost("backward.fill", "上一首") { music.previous() }
            Button { music.togglePlay() } label: {
                Image(systemName: music.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: Icon.play))
                    .foregroundStyle(Palette.listenNight)
                    .frame(width: Space.row, height: Space.row)
                    .background(Palette.onPhoto, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel(music.playing ? Text("暂停") : Text("接着听"))
            ghost("forward.fill", "下一首") { music.next() }
            Spacer()
        }
    }

    private func ghost(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Icon.plus))
                .foregroundStyle(Palette.onPhoto.opacity(0.6))
                .frame(width: Icon.menuCircle, height: Icon.menuCircle)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(LocalizedStringKey(label))
    }
}
