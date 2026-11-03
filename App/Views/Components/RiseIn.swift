import SwiftUI

/// 新出现的消息（像 iMessage）：这一行一进来就是它本来的高度，气泡从它那一边的下角放大、显现，轻轻一弹；
/// 你发的那条还会从下面（输入框那里）升上来一点。上面的消息让开，交给聊天页带动画滚到最新（同一条 Motion.bubble）。
/// 以前这一行的高度是一帧一帧长出来的，和滚动各算各的「底」，真机录屏里整列消息会先往下掉一截再往上窜。旧内容直接显示，不重播
struct RiseIn: ViewModifier {
    let fresh: Bool
    var anchor: UnitPoint = .bottom
    /// 从下面升上来多少（你发的消息：从输入框那里升上来）
    var rise: CGFloat = 0
    @State private var popped = false

    func body(content: Content) -> some View {
        let pop = !fresh || popped
        // 减少动态效果：不放大、不升，只在原地淡入
        let still = Motion.reduced
        content
            .scaleEffect(pop || still ? 1 : 0.8, anchor: anchor)
            .offset(y: pop || still ? 0 : rise)
            .opacity(pop ? 1 : 0)
            .onAppear {
                guard fresh, !popped else { return }
                withAnimation(Motion.bubblePop) { popped = true }
            }
    }
}

extension View {
    /// 出现只由 RiseIn 自己来演，不再叠一层列表默认的淡入（两层淡入节奏不同，看起来像闪了一下）；
    /// 拿掉时（多出来的「正在输入」、删除）像 iMessage 一样朝自己那一边的下角缩回去、淡掉
    func riseIn(fresh: Bool, anchor: UnitPoint = .bottom, rise: CGFloat = 0) -> some View {
        modifier(RiseIn(fresh: fresh, anchor: anchor, rise: rise))
            .transition(.asymmetric(insertion: .identity,
                                    removal: Motion.reduced ? .opacity : .opacity.combined(with: .scale(scale: 0.8, anchor: anchor))))
    }
}
