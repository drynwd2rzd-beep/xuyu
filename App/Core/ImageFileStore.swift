import UIKit

/// 单张图片存成一个文件（我的头像、照片小组件）：存之前缩小成 jpg，界面读的时候有缓存；
/// 每次换图改一下 stampKey 里的时间，界面看到它变了就重新读图
final class ImageFileStore {
    let file: Storage.File
    let stampKey: String
    private let maxSide: CGFloat
    private var cache: UIImage?
    private var loaded = false

    init(_ file: Storage.File, maxSide: CGFloat, stampKey: String) {
        self.file = file
        self.maxSide = maxSide
        self.stampKey = stampKey
    }

    var image: UIImage? {
        if !loaded {
            loaded = true
            cache = fileData.flatMap(UIImage.init(data:))
        }
        return cache
    }

    /// 文件本身（已经是缩小过的 jpg）：备份在后台读它，不碰界面用的缓存
    var fileData: Data? { Storage.readData(file.rawValue) }

    /// 换一张；写不进去时返回 false（Storage 已经提示过「没能保存」），界面上保持原来那张
    @discardableResult
    func save(_ data: Data) -> Bool {
        guard let jpeg = ImageUtil.downscale(data, maxSide: maxSide), Storage.writeData(jpeg, to: file.rawValue) else { return false }
        cache = UIImage(data: jpeg)
        loaded = true
        touch()
        return true
    }

    func clear() {
        Storage.remove(file)
        cache = nil
        loaded = true
        touch()
    }

    private func touch() {
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: stampKey)
    }

    /// 你自己的头像照片
    static let myAvatar = ImageFileStore(.myAvatar, maxSide: 400, stampKey: Prefs.myAvatarStamp)
    /// 照片小组件里你选的那张
    static let widgetPhoto = ImageFileStore(.widgetPhoto, maxSide: 1200, stampKey: Prefs.widgetPhotoStamp)
}
