import SwiftUI
import UIKit

/// 聊天这一层：盖在所有页面上面。
/// 打开：底下的页面轻轻变暗，聊天页从稍低的地方浮上来；返回正好反过来。
/// 从左边缘往右滑可以跟着手指返回，底下的页面也跟着一点点亮回来
struct ChatLayer: View {
    let id: UUID
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var context

    var body: some View {
        @Bindable var router = router
        GeometryReader { geo in
            NavigationStack(path: $router.chatPath) {
                Group {
                    if let convo = context.conversation(id) { ChatView(convo: convo) } else { Palette.paper }
                }
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            // 侧滑时整页在动，四角露在屏幕中间：跟屏幕一样圆；停下来恢复成方的（贴着屏幕边，看不出来）
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            // 侧滑时左边投一道阴影：投在同样圆角的底板上，不是给页面里每样东西各投一层
            .background(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Palette.paper)
                .shadow(color: .black.opacity(router.chatSwipe > 0 ? 0.18 : 0), radius: 18, x: -4)
                .ignoresSafeArea())
            .offset(x: router.chatSwipe * geo.size.width)
            // 从左边缘开始往右滑：返回。用系统返回手势同一种「屏幕边缘滑动」识别：
            // 认定是边缘滑动后，聊天列表不会再跟着上下滚，页面只左右走，不发颤。
            // 聊天里又点进别的页面时，交给系统自己的返回手势
            .gesture(EdgeSwipe(enabled: router.chatPath.isEmpty, onChange: { dx in
                router.chatSwipe = min(1, max(0, dx) / geo.size.width)
            }, onEnd: { dx, velocity in
                if router.chatSwipe > 0.35 || velocity > 800 {
                    withAnimation(Motion.depth) { router.chatSwipe = 1 }
                    router.closeChat()
                } else {
                    withAnimation(Motion.settle) { router.chatSwipe = 0 }
                }
            }))
        }
    }

    /// 整页在动时用屏幕的圆角，停着时是方的
    private var corner: CGFloat { router.chatSwipe > 0 ? Radius.screen : 0 }
}

/// 从屏幕左边缘往右滑（和系统返回手势同一种识别方式）：横着滑动时不会被上下滚动抢走
struct EdgeSwipe: UIGestureRecognizerRepresentable {
    /// 聊天里又点进了别的页面时关掉，交给那一页自己的系统返回手势
    var enabled: Bool
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIScreenEdgePanGestureRecognizer {
        let pan = UIScreenEdgePanGestureRecognizer()
        pan.edges = .left
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIScreenEdgePanGestureRecognizer, context: Context) {
        context.coordinator.enabled = enabled
    }

    func handleUIGestureRecognizerAction(_ pan: UIScreenEdgePanGestureRecognizer, context: Context) {
        let dx = pan.translation(in: pan.view).x
        switch pan.state {
        case .changed: onChange(dx)
        case .ended, .cancelled, .failed: onEnd(dx, pan.velocity(in: pan.view).x)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled = true

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { enabled }

        /// 边缘滑动开始后，让页面里的滚动先让路
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
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
