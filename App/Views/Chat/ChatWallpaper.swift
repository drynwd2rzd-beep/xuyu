import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import CoreImage

/// 聊天背景：全局一张，每个对话也可以单独设一张（owner 为对话 id）
enum WallpaperStore {
    /// 每个对话自己的背景选择；-1 表示跟随全局
    static func key(_ owner: UUID) -> String { "wallpaper.\(owner.uuidString)" }
    /// 照片每次更换都会改这个值，让界面重新读图
    static let stampKey = Prefs.wallpaperStamp

    static func url(_ owner: UUID?) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(owner.map { "wallpaper-\($0.uuidString).jpg" } ?? "wallpaper.jpg")
    }

    static func save(_ data: Data, for owner: UUID? = nil) {
        guard let jpeg = ImageUtil.downscale(data, maxSide: 2000, quality: 0.85) else { return }
        try? jpeg.write(to: url(owner), options: .atomic)
        cache[owner] = nil
        brightness[owner] = nil
        blurCache.removeAll()
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: stampKey)
    }

    /// 对话被删除时一并清掉
    static func remove(for owner: UUID) {
        try? FileManager.default.removeItem(at: url(owner))
        cache[owner] = nil
        brightness[owner] = nil
        blurCache.removeAll()
        UserDefaults.standard.removeObject(forKey: key(owner))
    }

    /// 还原设置 / 恢复出厂时：选过的背景照片（全局的和每个对话的）全部删掉
    static func removeAllPhotos() {
        let dir = url(nil).deletingLastPathComponent()
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix("wallpaper") {
            try? FileManager.default.removeItem(at: file)
        }
        cache.removeAll()
        brightness.removeAll()
        blurCache.removeAll()
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: stampKey)
    }

    /// 照片背景的明暗（-0.6 更暗 … 0.6 更亮）和模糊（0…24），每个背景各存一份
    static func dimKey(_ owner: UUID?) -> String { owner.map { "wallpaperDim.\($0.uuidString)" } ?? "wallpaperDim" }
    static func blurKey(_ owner: UUID?) -> String { owner.map { "wallpaperBlur.\($0.uuidString)" } ?? "wallpaperBlur" }
    static let defaultDim = 0.15

    static func adjustments(for owner: UUID?) -> (dim: Double, blur: Double) {
        let d = UserDefaults.standard
        return (d.object(forKey: dimKey(owner)) as? Double ?? defaultDim, d.double(forKey: blurKey(owner)))
    }

    /// 对话自己设了背景就用自己的，否则跟随全局
    static func resolve(for convoID: UUID, global: Int) -> (index: Int, owner: UUID?) {
        let own = UserDefaults.standard.object(forKey: key(convoID)) as? Int ?? -1
        return own >= 0 ? (own, convoID) : (global, nil)
    }

    private static var cache: [UUID?: UIImage] = [:]
    private static var brightness: [UUID?: Double] = [:]

    /// 照片背景有多亮（0 黑 … 1 白），算上你调的明暗；用来决定聊天页用深色还是浅色的字
    static func luminance(for owner: UUID?) -> Double? {
        guard let image = image(for: owner) else { return nil }
        let base: Double
        if let cached = brightness[owner] {
            base = cached
        } else {
            guard let cg = image.cgImage else { return nil }
            var pixel = [UInt8](repeating: 0, count: 4)
            let space = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            base = (0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])) / 255
            brightness[owner] = base
        }
        let dim = adjustments(for: owner).dim
        return dim >= 0 ? base + (1 - base) * dim : base * (1 + dim)
    }

    /// 每张背景只留最近一次的模糊结果（拖模糊滑杆时不会越存越多）
    private static var blurCache: [UUID?: (radius: Int, image: UIImage)] = [:]
    private static let ciContext = CIContext()

    /// 模糊过的背景：算一次存起来。每一帧现算模糊的话，进出聊天、滚动时都会掉帧。
    /// 模糊后看不出细节，先缩小再算，快很多；半径换算成和屏幕上看到的一样
    static func blurred(for owner: UUID?, radius: Double) -> UIImage? {
        guard let image = image(for: owner) else { return nil }
        guard radius > 0.5, let cg = image.cgImage else { return image }
        let key = Int(radius * 10)
        if let hit = blurCache[owner], hit.radius == key { return hit.image }
        guard let result = render(cg, radius: radius, screen: UIScreen.main.bounds.size) else { return image }
        blurCache[owner] = (key, result)
        return result
    }

    /// App 一打开就在后台把模糊背景算好：第一次进聊天时不用当场算（当场算正好卡在进场动画里）
    static func prewarm(_ owners: [UUID?]) {
        let screen = UIScreen.main.bounds.size
        for owner in Set(owners) {
            let radius = adjustments(for: owner).blur
            let key = Int(radius * 10)
            guard radius > 0.5, blurCache[owner]?.radius != key else { continue }
            let file = url(owner)
            Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: file), let image = UIImage(data: data), let cg = image.cgImage,
                      let result = render(cg, radius: radius, screen: screen) else { return }
                await MainActor.run {
                    if cache[owner] == nil { cache[owner] = image }
                    blurCache[owner] = (key, result)
                }
            }
        }
    }

    /// 模糊一张图。模糊后看不出细节，先缩小再算，快很多；半径换算成铺满屏幕时看到的大小
    private static func render(_ cg: CGImage, radius: Double, screen: CGSize) -> UIImage? {
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        // 铺满屏幕时，1 个像素占多少点
        let fill = max(screen.width / width, screen.height / height)
        let shrink = min(1, 1000 / max(width, height))
        var input = CIImage(cgImage: cg)
        if shrink < 1 { input = input.transformed(by: CGAffineTransform(scaleX: shrink, y: shrink)) }
        let extent = input.extent
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: radius / fill * shrink).cropped(to: extent)
        return ciContext.createCGImage(output, from: extent).map { UIImage(cgImage: $0) }
    }

    static func image(for owner: UUID? = nil) -> UIImage? {
        if let hit = cache[owner] { return hit }
        guard let data = try? Data(contentsOf: url(owner)), let image = UIImage(data: data) else { return nil }
        cache[owner] = image
        return image
    }
}

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
            if index == 3, let image = WallpaperStore.blurred(for: owner, radius: WallpaperStore.adjustments(for: owner).blur) {
                let adjust = WallpaperStore.adjustments(for: owner)
                Color.clear.overlay {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .overlay(adjust.dim >= 0 ? Color.white.opacity(adjust.dim) : Color.black.opacity(-adjust.dim))
            } else {
                Self.swatches[min(max(index, 0), 2)].1
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
            _selection = AppStorage(wrappedValue: -1, WallpaperStore.key(owner))
        } else {
            _selection = AppStorage(wrappedValue: 0, Prefs.wallpaper)
        }
        _dim = AppStorage(wrappedValue: WallpaperStore.defaultDim, WallpaperStore.dimKey(owner))
        _blur = AppStorage(wrappedValue: 0, WallpaperStore.blurKey(owner))
    }

    private var hasPhoto: Bool { selection == 3 && WallpaperStore.image(for: owner) != nil }

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
                pick(-1, "跟随") {
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
                swatch(3, "照片") {
                    if selection == 3, let image = WallpaperStore.image(for: owner) {
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
                    withAnimation(Motion.spring) { selection = 3 }
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
