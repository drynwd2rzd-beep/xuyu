import SwiftUI
import SwiftData
import PhotosUI

/// 照片小组件里自己选的那张照片
enum WidgetPhotoStore {
    static let stampKey = Prefs.widgetPhotoStamp

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("widget-photo.jpg")
    }

    private static var cache: UIImage?
    private static var loaded = false

    static var image: UIImage? {
        if !loaded {
            loaded = true
            cache = (try? Data(contentsOf: url)).flatMap { UIImage(data: $0) }
        }
        return cache
    }

    static func save(_ data: Data) {
        guard let jpeg = ImageUtil.downscale(data, maxSide: 1200) else { return }
        try? jpeg.write(to: url, options: .atomic)
        cache = UIImage(data: jpeg)
        loaded = true
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: stampKey)
    }
}

/// 照片：放一张你自己选的照片，点一下可以换
struct PhotoWidget: View {
    @AppStorage(WidgetPhotoStore.stampKey) private var stamp = 0.0

    var body: some View {
        ZStack {
            if let image = WidgetPhotoStore.image {
                Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }
                    .transition(.opacity)
            } else {
                Palette.fill
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 24, weight: .light))
                    Text("点一下选照片").font(.system(size: 12))
                }
                .foregroundStyle(Palette.inkSoft)
            }
        }
        .id(stamp)
        .frame(maxWidth: .infinity, minHeight: 136, maxHeight: 136)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .background { CardShadow() }
    }
}
