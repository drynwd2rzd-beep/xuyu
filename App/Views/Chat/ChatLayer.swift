import SwiftUI

/// 聊天这一层：盖在所有页面上面。
/// 打开：底下的页面往后退（微微缩小、圆角、变暗），聊天页从稍低的地方浮上来、渐渐清晰；返回正好反过来。
/// 从左边缘往右滑可以跟着手指返回，底下的页面也跟着一点点回到前面
struct ChatLayer: View {
    let id: UUID
    /// 侧滑返回的进度 0～1，底下的页面据此回到前面
    @Binding var swipe: CGFloat
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var context
    @State private var drag: CGFloat = 0

    var body: some View {
        @Bindable var router = router
        GeometryReader { geo in
            NavigationStack(path: $router.chatPath) {
                Group {
                    if let convo = context.conversation(id) { ChatView(convo: convo) } else { Palette.paper }
                }
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            // 侧滑时左边投一道阴影（投在底板上，不是给页面里每样东西各投一层）
            .background(Rectangle().fill(Palette.paper).shadow(color: .black.opacity(drag > 0 ? 0.18 : 0), radius: 18, x: -4).ignoresSafeArea())
            .offset(x: drag)
            // 从左边缘开始往右滑：返回。和按钮、滚动同时识别，不会挡住左上角的返回键和输入框旁的按钮；
            // 聊天里又点进别的页面时，交给系统自己的返回手势
            .simultaneousGesture(edgeSwipe(width: geo.size.width), including: router.chatPath.isEmpty ? .all : .subviews)
        }
    }

    /// 这次拖动是不是从左边缘开始的（只有这样才算侧滑返回）
    @State private var fromEdge = false

    private func edgeSwipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                if drag == 0 && !fromEdge {
                    fromEdge = value.startLocation.x < 24 && value.translation.width > abs(value.translation.height)
                }
                guard fromEdge else { return }
                drag = max(0, value.translation.width)
                swipe = min(1, drag / width)
            }
            .onEnded { value in
                guard fromEdge else { return }
                fromEdge = false
                let flung = value.predictedEndTranslation.width > width * 0.5
                if drag > width * 0.35 || flung {
                    withAnimation(Motion.depth) {
                        drag = width
                        swipe = 1
                    }
                    router.closeChat()
                } else {
                    withAnimation(Motion.settle) {
                        drag = 0
                        swipe = 0
                    }
                }
            }
    }
}

/// 聊天页出现、离开的样子：从稍低处浮上来、由虚变实；离开时沉下去、变虚、淡出
struct DepthTransition: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.97, anchor: .bottom)
            .offset(y: shown ? 0 : 36)
            .blur(radius: shown ? 0 : 6)
    }
}

extension AnyTransition {
    static var depth: AnyTransition {
        .modifier(active: DepthTransition(shown: false), identity: DepthTransition(shown: true))
    }
}

extension View {
    /// 聊天打开时，底下的页面往后退：微微缩小、四角变圆、蒙一层暗；侧滑返回时跟着手指一点点回来
    func recede(_ amount: CGFloat) -> some View {
        self
            .overlay(Color.black.opacity(0.14 * amount).ignoresSafeArea().allowsHitTesting(false))
            // 遮罩铺满整个屏幕（包括状态栏那一条），不会把背景裁掉；只是四角跟着变圆
            .mask(RoundedRectangle(cornerRadius: 44 * amount, style: .continuous).ignoresSafeArea())
            .scaleEffect(1 - 0.06 * amount)
    }
}
