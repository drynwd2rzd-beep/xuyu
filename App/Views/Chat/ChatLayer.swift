import SwiftUI
import UIKit

/// 聊天这一层：盖在所有页面上面，像穿梭一样进出。
/// 打开：聊天页从点的那一行由小变大、迎面铺满屏幕，底下的列表朝你放大、淡开，像从它中间穿过去。
/// 返回：聊天页像雾一样散开，列表从放大的状态退回原位、由淡变清晰。
/// 从左边缘往右滑：聊天页跟着手指缩小，底下的列表一点点回来
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
            // 侧滑时整页缩小、四角露在屏幕中间：跟屏幕一样圆；停下来恢复成方的（贴着屏幕边，看不出来）
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .background(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Palette.paper)
                .shadow(color: .black.opacity(0.2 * router.chatSwipe), radius: 24, y: 10)
                .ignoresSafeArea())
            .scaleEffect(1 - 0.18 * router.chatSwipe)
            .offset(x: router.chatSwipe * geo.size.width * 0.5)
            // 从左边缘开始往右滑：返回。用系统返回手势同一种「屏幕边缘滑动」识别：
            // 认定是边缘滑动后，聊天列表不会再跟着上下滚，页面只跟着手指走，不发颤。
            // 聊天里又点进别的页面时，交给系统自己的返回手势
            .gesture(EdgeSwipe(enabled: router.chatPath.isEmpty, onChange: { dx in
                router.chatSwipe = min(1, max(0, dx) / geo.size.width)
            }, onEnd: { _, velocity in
                if router.chatSwipe > 0.3 || velocity > 800 {
                    // 从现在缩着的样子接着散开
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

/// 穿梭：progress 1 是铺满屏幕。
/// 进入（0 → 1）：从点的那一行那么小、那一行的位置，一边变大一边显现，迎面铺满。
/// 退出（1 → 0）：像雾一样散开：在原地微微放大、变朦胧、慢慢透明，透出后面的列表。
/// 一帧一帧按进度算（Animatable），进入和退出可以是两种完全不同的样子
struct ShuttleEffect: ViewModifier, Animatable {
    var progress: CGFloat
    let origin: CGRect?
    let leaving: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress
        if leaving {
            return AnyView(content
                .scaleEffect(1 + 0.08 * (1 - p))
                .blur(radius: 14 * (1 - p))
                .opacity(Double(p)))
        }
        let screen = UIScreen.main.bounds
        // 没有那一行（从主页、通知进来）：从屏幕中间
        let from = origin ?? CGRect(x: 0, y: screen.midY - 36, width: screen.width, height: 72)
        return AnyView(content
            .clipShape(RoundedRectangle(cornerRadius: (1 - p) * 40, style: .continuous))
            .scaleEffect(0.18 + 0.82 * p)
            .offset(x: (from.midX - screen.midX) * (1 - p), y: (from.midY - screen.midY) * (1 - p))
            .opacity(Double(min(1, p * 1.4))))
    }
}

extension AnyTransition {
    /// 进出聊天的穿梭过渡：从 origin（点的那一行）飞进来，返回时飞回去
    static func shuttle(from origin: CGRect?) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: ShuttleEffect(progress: 0, origin: origin, leaving: false),
                                 identity: ShuttleEffect(progress: 1, origin: origin, leaving: false)),
            removal: .modifier(active: ShuttleEffect(progress: 0, origin: origin, leaving: true),
                               identity: ShuttleEffect(progress: 1, origin: origin, leaving: true))
        )
    }
}

extension View {
    /// 聊天开着时，底下的页面朝你放大、淡开（像从它中间穿过去）；侧滑或返回时跟着回到原位、亮回来。
    /// 只用缩放和透明度，不模糊；放大不会露出边
    func recede(_ amount: CGFloat) -> some View {
        scaleEffect(1 + 0.12 * amount)
            .opacity(Double(1 - 0.85 * amount))
    }
}
