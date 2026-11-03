import SwiftUI

/// 主页画册的一页：占满一屏，像翻摄影集一样上下翻（HomeView 里按页对齐）。
/// 左上角一行小字说明这一页是什么，右上角页码「02 / 06」；压在照片、深色上时字是白的
struct PhotobookPage<Background: View, Content: View>: View {
    let folio: String
    let number: Int
    let total: Int
    /// 压在照片或深色底上：页眉用白字
    var onDark = false
    /// 页眉右边换成别的（封面上是进设置的头像）
    var trailing: AnyView? = nil
    /// 点页眉那行字（封面上：打开月历）
    var onFolio: (() -> Void)? = nil
    @ViewBuilder var background: Background
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.horizontal, Space.book)
                .padding(.bottom, Space.bookBottom)
            header
                .padding(.horizontal, Space.book)
                .padding(.top, Space.bookTop)
        }
        .containerRelativeFrame([.horizontal, .vertical])
        .clipped()
    }

    private var header: some View {
        HStack(alignment: .center) {
            if let onFolio {
                Button(action: onFolio) {
                    Text(verbatim: folio)
                        .frame(minHeight: Space.control)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开月历")
                .accessibilityIdentifier("monthToggle")
            } else {
                Text(verbatim: folio)
            }
            Spacer()
            if let trailing {
                trailing
            } else if number > 1 {
                Text(verbatim: String(format: "%02d / %02d", number, total)).monospacedDigit()
            }
        }
        .font(.system(size: Typo.caption))
        .tracking(Typo.tracking * 2)
        .foregroundStyle(onDark ? Palette.onPhoto.opacity(0.88) : Palette.inkSoft)
    }
}

extension View {
    /// 翻到这一页时字慢慢浮现：从下面一点、糊的，变清楚。order 越大越晚出来。
    /// 减弱动态效果时只淡入（MOTION-3）
    func reveal(_ order: Int = 0) -> some View {
        let still = Motion.reduced
        return scrollTransition(.animated(Motion.reveal.delay(Double(order) * Motion.revealStep))) { effect, phase in
            effect
                .opacity(phase.isIdentity ? 1 : 0)
                .offset(y: phase.isIdentity || still ? 0 : Space.tight)
                .blur(radius: phase.isIdentity || still ? 0 : 4)
        }
    }
}

/// 铺满一页的照片：统一调色，上下两头压暗一点，白字压在上面看得清
struct PhotobookPhoto: View {
    let image: UIImage

    var body: some View {
        Color.clear
            .overlay { Image(uiImage: image).resizable().scaledToFill().graded() }
            .overlay {
                LinearGradient(stops: [
                    .init(color: Palette.photoShade.opacity(0.3), location: 0),
                    .init(color: Palette.photoShade.opacity(0), location: 0.2),
                    .init(color: Palette.photoShade.opacity(0), location: 0.46),
                    .init(color: Palette.photoShade.opacity(0.58), location: 0.82),
                    .init(color: Palette.photoShade.opacity(0.7), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .accessibilityHidden(true)
    }
}

/// 照片下面那一行小字：名字 · 时间 · 第几天，中间用小圆点隔开
struct Byline: View {
    let parts: [String]
    var onDark = true

    var body: some View {
        HStack(spacing: Space.tight) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Circle().frame(width: 2, height: 2).opacity(0.6) }
                Text(verbatim: part)
            }
        }
        .font(.system(size: Typo.caption))
        .tracking(Typo.tracking)
        .foregroundStyle(onDark ? Palette.onPhoto.opacity(0.78) : Palette.inkSoft)
    }
}
