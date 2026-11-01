import SwiftUI
import UIKit
import CoreImage

/// 聊天背景：全局一张，每个对话也可以单独设一张（owner 为对话 id）
enum WallpaperStore {
    /// 背景选的是哪一个：存的是它的数字（Prefs.wallpaper、Prefs.wallpaperOf），数字不能改（DATA-5）
    enum Choice: Int {
        /// 对话自己不设，跟随全局
        case follow = -1
        case paper, mist, night, photo
    }

    /// 照片每次更换都会改这个值，让界面重新读图
    static let stampKey = Prefs.wallpaperStamp

    /// 照片文件名：全局一张，每个对话一张（都以 Storage.wallpaperPrefix 开头）
    private static func fileName(_ owner: UUID?) -> String {
        owner.map { "\(Storage.wallpaperPrefix)-\($0.uuidString).jpg" } ?? "\(Storage.wallpaperPrefix).jpg"
    }

    static func url(_ owner: UUID?) -> URL { Storage.url(fileName(owner)) }

    /// 写不进去时 Storage 已经提示过「没能保存」，原来的背景照旧
    static func save(_ data: Data, for owner: UUID? = nil) {
        guard let jpeg = ImageUtil.downscale(data, maxSide: 2000, quality: 0.85), Storage.writeData(jpeg, to: fileName(owner)) else { return }
        cache[owner] = nil
        brightness[owner] = nil
        blurCache.removeAll()
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: stampKey)
    }

    /// 对话被删除时一并清掉：照片、选择、明暗和模糊
    static func remove(for owner: UUID) {
        Storage.remove(fileName(owner))
        cache[owner] = nil
        brightness[owner] = nil
        blurCache.removeAll()
        for key in [Prefs.wallpaperOf(owner), Prefs.wallpaperDimOf(owner), Prefs.wallpaperBlurOf(owner)] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// 还原设置 / 恢复出厂时：选过的背景照片（全局的和每个对话的）全部删掉
    static func removeAllPhotos() {
        for name in Storage.names(prefix: Storage.wallpaperPrefix) { Storage.remove(name) }
        cache.removeAll()
        brightness.removeAll()
        blurCache.removeAll()
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: stampKey)
    }

    /// 照片背景的明暗（-0.6 更暗 … 0.6 更亮）和模糊（0…24），每个背景各存一份
    static let defaultDim = 0.15

    static func adjustments(for owner: UUID?) -> (dim: Double, blur: Double) {
        let d = UserDefaults.standard
        return (d.object(forKey: Prefs.wallpaperDimOf(owner)) as? Double ?? defaultDim, d.double(forKey: Prefs.wallpaperBlurOf(owner)))
    }

    /// 对话自己设了背景就用自己的，否则跟随全局
    static func resolve(for convoID: UUID, global: Int) -> (index: Int, owner: UUID?) {
        let own = UserDefaults.standard.object(forKey: Prefs.wallpaperOf(convoID)) as? Int ?? Choice.follow.rawValue
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
