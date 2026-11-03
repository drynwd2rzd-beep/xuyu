import SwiftUI

/// 列表行：按下时一块圆角浅灰淡淡浮现，松手后慢慢退去（行之间不加线，按下的底色也不顶到边）
struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Palette.card.opacity(configuration.isPressed ? 1 : 0), in: .rounded(Radius.control))
            .animation(configuration.isPressed ? Motion.pressIn : Motion.pressOut, value: configuration.isPressed)
    }
}

/// 按钮、卡片：按下缩到 0.97，松手柔和回来（设计规范：全部用弹簧，不弹跳）
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(configuration.isPressed ? Motion.pressIn : Motion.pressOut, value: configuration.isPressed)
    }
}
