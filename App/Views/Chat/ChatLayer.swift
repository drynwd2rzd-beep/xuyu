import SwiftUI

/// 聊天这一层：盖在所有页面上面。
/// 打开：底下的页面往后退（微微缩小、圆角、变暗），聊天页从稍低的地方浮上来、渐渐清晰；返回正好反过来。
/// 从左边缘往右滑可以跟着手指返回，底下的页面也跟着一点点回到前面
struct ChatLayer: View {
    let id: UUID
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var context
    /// 这次拖动是不是从左边缘开始的（只有这样才算侧滑返回）
    @State private var fromEdge = false

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
            .background(Rectangle().fill(Palette.paper)
                .shadow(color: .black.opacity(router.chatSwipe > 0 ? 0.18 : 0), radius: 18, x: -4)
                .ignoresSafeArea())
            .offset(x: router.chatSwipe * geo.size.width)
            // 从左边缘开始往右滑：返回。和按钮、滚动同时识别，不会挡住左上角的返回键和输入框旁的按钮；
            // 聊天里又点进别的页面时，交给系统自己的返回手势
            .simultaneousGesture(edgeSwipe(width: geo.size.width), including: router.chatPath.isEmpty ? .all : .subviews)
        }
    }

    private func edgeSwipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                if router.chatSwipe == 0 && !fromEdge {
                    fromEdge = value.startLocation.x < 24 && value.translation.width > abs(value.translation.height)
                }
                guard fromEdge else { return }
                router.chatSwipe = min(1, max(0, value.translation.width) / width)
            }
            .onEnded { value in
                guard fromEdge else { return }
                fromEdge = false
                let flung = value.predictedEndTranslation.width > width * 0.5
                if router.chatSwipe > 0.35 || flung {
                    withAnimation(Motion.depth) { router.chatSwipe = 1 }
                    router.closeChat()
                } else {
                    withAnimation(Motion.settle) { router.chatSwipe = 0 }
                }
            }
    }
}

/// 聊天页出现、离开的样子：从稍低处淡淡地浮上来；离开时沉下去、淡出。
/// 只用透明度和位移（不模糊、不缩放整屏），每一帧都很省，不会掉帧
struct DepthTransition: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 28)
    }
}

extension AnyTransition {
    static var depth: AnyTransition {
        .modifier(active: DepthTransition(shown: false), identity: DepthTransition(shown: true))
    }
}

extension View {
    /// 聊天打开时，底下的页面轻轻变暗（不缩小，所以不会露出黑边）；侧滑返回时跟着手指一点点亮回来
    func recede(_ amount: CGFloat) -> some View {
        overlay(Color.black.opacity(0.12 * amount).ignoresSafeArea().allowsHitTesting(false))
    }
}
