import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import CoreImage

/// 聊天里的一行越靠近页头（名字那里）、越靠近输入栏，就越糊。只糊消息本身，背景照片一直清楚；
/// 是这一行自己的效果，进出聊天的动画途中也照样画得出来（系统的毛玻璃不行，只能等进去以后再加，会突然糊一下）。
/// 按这一行的中线算，从屏幕顶上往下一路慢慢变清楚：页头下沿往下 40 点开始有一丝，越往上越糊，到最顶上最多 4，
/// 中间按缓入曲线走，名字那里只有一点点（那里的字本来也快看不见了）。输入栏上沿附近最多 2。
/// 以前：最多 7、名字下面 70 点就开始，页头下面还看得清的卡片字已经糊成一片
struct EdgeBlur: ViewModifier {
    let headerBottom: CGFloat
    let barTop: CGFloat

    func body(content: Content) -> some View {
        content.visualEffect { [headerBottom, barTop] effect, proxy in
            effect.blur(radius: edgeBlurRadius(proxy.frame(in: .named("chatContent")), headerBottom: headerBottom, barTop: barTop))
        }
    }
}

/// 见 EdgeBlur。还没量到页头 / 输入栏（0）时不糊
func edgeBlurRadius(_ frame: CGRect, headerBottom: CGFloat, barTop: CGFloat) -> CGFloat {
    var radius: CGFloat = 0
    if headerBottom > 0 {
        let up = min(1, max(0, (headerBottom + 40 - frame.midY) / 150))
        radius = up * up * 4
    }
    if barTop > 0 {
        let down = (frame.maxY - (barTop - 4)) / 40
        radius = max(radius, min(1, max(0, down)) * 2)
    }
    return radius
}

/// 聊天记录在页头和输入栏那里淡出（照灵感视频）：和 EdgeBlur 一起，消息一边变糊一边变透明。
/// 顶上：从屏幕最上面完全透明开始，一路慢慢变清楚，到名字那一行还只剩一点影子，页头下面 50 点完全显出来；
/// 底部：从输入栏上沿一点点开始淡，输入栏后面看不到消息，停着不动时最后一条消息不受影响。
/// headerBottom / barTop 是页头下沿、输入栏上沿在 ChatView.space 里的位置
/// （不能用安全区去量：这里读出来是 0，第一版就因为这个整个没生效）
struct ChatEdgeMask: View {
    let headerBottom: CGFloat
    let barTop: CGFloat

    var body: some View {
        GeometryReader { g in
            let origin = g.frame(in: .named(ChatView.space)).minY
            let height = g.size.height
            // 从屏幕顶上到页头下面 50 点是一整段渐变（缓入：上面很久都几乎看不见，过了名字才快起来）
            let top = max(0, headerBottom - origin) + 50
            // 还没量到输入栏时不淡（不然整屏消息都会被当成在输入栏后面）
            let bar = barTop > 0 ? barTop - origin : height
            VStack(spacing: 0) {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.02), location: 0.3),
                    .init(color: .black.opacity(0.06), location: 0.55),
                    .init(color: .black.opacity(0.16), location: 0.72),
                    .init(color: .black.opacity(0.45), location: 0.85),
                    .init(color: .black.opacity(0.8), location: 0.94),
                    .init(color: .black, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: top)
                Color.black
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.55), location: 0.4),
                    .init(color: .black.opacity(0.15), location: 0.75),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: 22)
                Color.clear.frame(height: max(0, height - bar - 18))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}



struct ChatWallpaper: View {
    let index: Int
    var owner: UUID? = nil
    /// 作为整页背景时铺满到屏幕边缘；放在页头里对齐用时不需要
    var edgeToEdge = true

    static let swatches: [(String, Color)] = [
        ("纸白", Palette.paper),
        ("雾灰", Color.dynamic(light: 0xE3E4E2, dark: 0x17181A)),
        ("夜墨", Color(hex: 0x1C1C1E)),
    ]

    var body: some View {
        Group {
            if index == WallpaperStore.Choice.photo.rawValue, let image = WallpaperStore.blurred(for: owner, radius: WallpaperStore.adjustments(for: owner).blur) {
                let adjust = WallpaperStore.adjustments(for: owner)
                Color.clear.overlay {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .overlay(adjust.dim >= 0 ? Color.white.opacity(adjust.dim) : Color.black.opacity(-adjust.dim))
            } else {
                Self.swatches[min(max(index, WallpaperStore.Choice.paper.rawValue), WallpaperStore.Choice.night.rawValue)].1
            }
        }
        .ignoresSafeArea(edges: edgeToEdge ? .all : [])
    }
}

/// 背景选择：一排色块 + 自定义照片；owner 不为空时多一个「跟随」
struct WallpaperPicker: View {
    let owner: UUID?
    @AppStorage(WallpaperStore.stampKey) private var stamp = 0.0
    @AppStorage private var selection: Int
    @AppStorage private var dim: Double
    @AppStorage private var blur: Double
    @State private var item: PhotosPickerItem?

    init(owner: UUID?) {
        self.owner = owner
        if let owner {
            _selection = AppStorage(wrappedValue: WallpaperStore.Choice.follow.rawValue, Prefs.wallpaperOf(owner))
        } else {
            _selection = AppStorage(wrappedValue: 0, Prefs.wallpaper)
        }
        _dim = AppStorage(wrappedValue: WallpaperStore.defaultDim, Prefs.wallpaperDimOf(owner))
        _blur = AppStorage(wrappedValue: 0, Prefs.wallpaperBlurOf(owner))
    }

    private var hasPhoto: Bool { selection == WallpaperStore.Choice.photo.rawValue && WallpaperStore.image(for: owner) != nil }

    var body: some View {
        VStack(spacing: Space.section) {
            swatches
            // 选了照片时可以调明暗和模糊
            if hasPhoto {
                VStack(spacing: Space.tight) {
                    adjustRow("明暗", value: $dim, range: -0.6...0.6, low: "sun.min", high: "sun.max")
                    adjustRow("模糊", value: $blur, range: 0...24, low: "drop", high: "drop.fill")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.spring, value: hasPhoto)
    }

    private func adjustRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           low: String, high: String) -> some View {
        HStack(spacing: Space.item) {
            Text(title).font(.system(size: 14)).foregroundStyle(Palette.ink).frame(width: 34, alignment: .leading)
            Image(systemName: low).font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
            Slider(value: value, in: range) { editing in
                // 松手时让聊天页换上新的效果
                if !editing { stamp = Date.now.timeIntervalSince1970 }
            }
            .tint(Palette.ink)
            Image(systemName: high).font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
        }
    }

    private var swatches: some View {
        HStack(spacing: 10) {
            if owner != nil {
                pick(WallpaperStore.Choice.follow.rawValue, "跟随") {
                    ZStack {
                        Palette.paper
                        Image(systemName: "circle.lefthalf.filled").font(.system(size: 17)).foregroundStyle(Palette.inkSoft)
                    }
                }
            }
            ForEach(0..<3, id: \.self) { i in
                pick(i, ChatWallpaper.swatches[i].0) { ChatWallpaper.swatches[i].1 }
            }
            PhotosPicker(selection: $item, matching: .images) {
                swatch(WallpaperStore.Choice.photo.rawValue, "照片") {
                    if selection == WallpaperStore.Choice.photo.rawValue, let image = WallpaperStore.image(for: owner) {
                        // 小预览也跟着明暗、模糊实时变化
                        Color.clear.overlay {
                            Image(uiImage: image).resizable().scaledToFill().blur(radius: blur / 4, opaque: true)
                        }
                        .overlay(dim >= 0 ? Color.white.opacity(dim) : Color.black.opacity(-dim))
                        .id(stamp)
                    } else {
                        ZStack {
                            Palette.paper
                            Image(systemName: "photo").font(.system(size: 17)).foregroundStyle(Palette.inkSoft)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .sensoryFeedback(.selection, trigger: selection)
        .onChange(of: selection) { _, _ in
            // 让正在显示的聊天页立刻换上
            withAnimation(Motion.spring) { stamp = Date.now.timeIntervalSince1970 }
        }
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            Task {
                if let data = try? await picked.loadTransferable(type: Data.self) {
                    WallpaperStore.save(data, for: owner)
                    withAnimation(Motion.spring) { selection = WallpaperStore.Choice.photo.rawValue }
                }
                item = nil
            }
        }
    }

    private func pick<C: View>(_ index: Int, _ label: String, @ViewBuilder fill: () -> C) -> some View {
        Button { withAnimation(Motion.spring) { selection = index } } label: { swatch(index, label, fill: fill) }
            .buttonStyle(.plain)
    }

    private func swatch<C: View>(_ index: Int, _ label: String, @ViewBuilder fill: () -> C) -> some View {
        VStack(spacing: 6) {
            fill()
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(selection == index ? Palette.ink : Palette.hairline, lineWidth: selection == index ? 2 : 0.5))
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.inkSoft).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}
