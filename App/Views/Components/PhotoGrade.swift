import SwiftUI
import CoreImage

/// 照片统一调色（设计规范「照片调色」）：降饱和到 60%、对比略降、整体略暖、加一层很淡的颗粒。
/// 动态、画册、聊天里的照片都用这一套，头像、表情、看大图不调（看大图要看原样）
struct PhotoGrade: ViewModifier {
    func body(content: Content) -> some View {
        content
            .saturation(0.6)
            .contrast(0.94)
            .overlay {
                ZStack {
                    Palette.photoWarmth.opacity(0.08).blendMode(.softLight)
                    if let grain = Grain.tile {
                        Image(decorative: grain, scale: 2)
                            .resizable(resizingMode: .tile)
                            .opacity(0.06)
                            .blendMode(.overlay)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

extension View {
    /// 照片统一调色
    func graded() -> some View { modifier(PhotoGrade()) }
}

/// 颗粒：一小块灰度噪点，平铺在照片上。只生成一次，之后所有照片共用
private enum Grain {
    /// 噪点块的边长（像素）
    private static let side: CGFloat = 160

    @MainActor static let tile: CGImage? = {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage,
              let mono = CIFilter(name: "CIColorControls", parameters: [kCIInputImageKey: noise, kCIInputSaturationKey: 0])?.outputImage
        else { return nil }
        return CIContext().createCGImage(mono, from: CGRect(x: 0, y: 0, width: side, height: side))
    }()
}
