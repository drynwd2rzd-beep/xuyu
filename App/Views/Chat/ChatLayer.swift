import SwiftUI
import UIKit

/// 聊天这一层：盖在所有页面上面，像穿梭一样进出。
/// 打开：聊天页从点的那一行由小变大、迎面铺满屏幕，底下的列表朝你放大、淡开，像从它中间穿过去。
/// 返回：聊天页像雾一样散开，列表从放大的状态退回原位、由淡变清晰。
/// 从左边缘往右滑：聊天页跟着手指往右走（一比一跟手），松手后带着速度滑出去或弹回来
struct ChatLayer: View {
    let id: UUID
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var context

    var body: some View {
        @Bindable var router = router
        let swipe = router.chatSwipe
        GeometryReader { geo in
            NavigationStack(path: $router.chatPath) {
                Group {
                    if let convo = context.conversation(id) { ChatView(convo: convo) } else { Palette.paper }
                }
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            // 裁切范围是整块屏幕（连同状态栏和底部横条那一截），聊天背景不会被切掉、露出上下两条黑边。
            // 侧滑时四角跟屏幕一样圆
            .clipShape(ScreenShape(radius: swipe > 0 ? Radius.screen : 0,
                                   top: geo.safeAreaInsets.top, bottom: geo.safeAreaInsets.bottom))
            .background {
                // 影子只在侧滑时出现，投在左边，像一张纸叠在列表上
                if swipe > 0 {
                    ScreenShape(radius: Radius.screen, top: geo.safeAreaInsets.top, bottom: geo.safeAreaInsets.bottom)
                        .fill(Palette.paper)
                        .shadow(color: .black.opacity(0.22 * (1 - swipe)), radius: 20, x: -6)
                }
            }
            .scaleEffect(1 - 0.06 * swipe)
            .offset(x: swipe * geo.size.width)
            // 从左边缘开始往右滑：返回。用系统返回手势同一种「屏幕边缘滑动」识别：
            // 认定是边缘滑动后，聊天列表不会再跟着上下滚，页面只跟着手指走，不发颤。
            // 聊天里又点进别的页面时，交给系统自己的返回手势
            .gesture(EdgeSwipe(enabled: router.chatPath.isEmpty, onBegin: {
                // 键盘不跟着页面走：开始滑就收起
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }, onChange: { dx in
                router.chatSwipe = min(1, max(0, dx) / geo.size.width)
            }, onEnd: { _, velocity in
                let v = velocity / geo.size.width
                // 滑过三分之一，或者往右甩了一下：返回
                if (router.chatSwipe > 0.33 && v > -0.3) || v > 0.9 {
                    router.swipeAway(velocity: v)
                } else {
                    router.swipeBack(velocity: v)
                }
            }))
        }
    }
}

/// 整块屏幕的形状：这一层只占安全区，往上下各伸出 top / bottom（状态栏、底部横条那一截）。
/// radius 为 0 时再往外多伸很多，等于不裁切
struct ScreenShape: Shape {
    var radius: CGFloat
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        if radius <= 0.5 { return Path(rect.insetBy(dx: -2000, dy: -2000)) }
        let screen = CGRect(x: rect.minX, y: rect.minY - top, width: rect.width, height: rect.height + top + bottom)
        return Path(roundedRect: screen, cornerRadius: radius, style: .continuous)
    }
}

/// 从屏幕左边缘往右滑（和系统返回手势同一种识别方式）：横着滑动时不会被上下滚动抢走
struct EdgeSwipe: UIGestureRecognizerRepresentable {
    /// 聊天里又点进了别的页面时关掉，交给那一页自己的系统返回手势
    var enabled: Bool
    var onBegin: () -> Void
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
        case .began: onBegin()
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
/// 一帧一帧按进度算（Animatable）。进入和退出是同一串效果、只是参数不同：
/// 换方向时页面本身不会被重建（聊天不会跳、不会闪一下）；在 progress 1 时两者完全一样，接得上
struct ShuttleEffect: ViewModifier, Animatable {
    var progress: CGFloat
    let origin: CGRect?
    let leaving: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let q = 1 - progress
        let screen = UIScreen.main.bounds
        let insets = Screen.insets
        // 没有那一行（从主页、通知进来）：从屏幕中间
        let from = origin ?? CGRect(x: 0, y: screen.midY - 36, width: screen.width, height: 72)
        // 这一层的中心是安全区的中心，不是屏幕的中心
        let center = CGPoint(x: screen.midX, y: insets.top + (screen.height - insets.top - insets.bottom) / 2)
        return content
            .clipShape(ScreenShape(radius: leaving ? 0 : q * 40, top: insets.top, bottom: insets.bottom))
            .scaleEffect(leaving ? 1 + 0.08 * q : 0.18 + 0.82 * progress)
            .offset(x: leaving ? 0 : (from.midX - center.x) * q, y: leaving ? 0 : (from.midY - center.y) * q)
            .blur(radius: leaving ? 14 * q : 0)
            .opacity(leaving ? Double(progress) : Double(min(1, progress * 1.4)))
    }
}

/// 屏幕四周的安全区（状态栏、底部横条）
enum Screen {
    static var insets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.safeAreaInsets ?? .zero
    }
}

extension AnyTransition {
    /// 进出聊天的穿梭过渡：从 origin（点的那一行）飞进来，返回时像雾一样散开
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
