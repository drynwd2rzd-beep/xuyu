import SwiftUI
import SwiftData
import PhotosUI

/// 照片：放一张你自己选的照片（见 ImageFileStore.widgetPhoto），点一下可以换
struct PhotoWidget: View {
    @AppStorage(Prefs.widgetPhotoStamp) private var stamp = 0.0

    var body: some View {
        ZStack {
            if let image = ImageFileStore.widgetPhoto.image {
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
