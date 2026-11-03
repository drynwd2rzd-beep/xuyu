import SwiftUI

/// 卡片：白底上的一块浅灰（Palette.card），不加阴影和描边。新版设计里只有悬浮的东西（底栏、顶栏胶囊）才有阴影
struct CardStyle: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content.background(Palette.card, in: .rounded(radius))
    }
}

extension View {
    func card(radius: CGFloat = Radius.card) -> some View { modifier(CardStyle(radius: radius)) }
}

/// 照片类小组件的底板：内容还没铺满（图片在加载）时先露出浅灰，不闪白
struct CardShadow: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(Palette.card)
    }
}
