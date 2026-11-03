import SwiftUI

/// 聊天气泡的形状（照 iMessage）：连续曲率的圆角块；一组的最后一条在自己那一边的下角带一个小尾巴。
/// 尾巴伸出气泡外一点，气泡本身的大小不变，有没有尾巴排版都一样
struct BubbleShape: Shape {
    /// 尾巴在哪一边：你的在右边，TA 的在左边；nil 表示这条不是一组的最后一条，不带尾巴
    var tail: HorizontalEdge?

    func path(in rect: CGRect) -> Path {
        let body = Path(roundedRect: rect, cornerRadius: Radius.bubble, style: .continuous)
        guard let tail else { return body }
        // 先按右边画，再按需要左右翻过来
        var hook = Path()
        let x = rect.maxX, y = rect.maxY
        hook.move(to: CGPoint(x: x - Self.root, y: y - Self.height))
        hook.addQuadCurve(to: CGPoint(x: x + Self.reach, y: y), control: CGPoint(x: x - Self.bend, y: y - Self.bend))
        hook.addQuadCurve(to: CGPoint(x: x - Self.height, y: y - Self.bend), control: CGPoint(x: x - Self.bend, y: y))
        hook.closeSubpath()
        if tail == .leading {
            hook = hook.applying(CGAffineTransform(translationX: rect.minX + rect.maxX, y: 0).scaledBy(x: -1, y: 1))
        }
        return body.union(hook)
    }

    /// 尾巴伸出气泡外多少
    private static let reach: CGFloat = 5
    /// 尾巴从气泡底边往上多高开始长出来
    private static let height: CGFloat = 16
    /// 尾巴根部离气泡边多远
    private static let root: CGFloat = 8
    /// 尾巴弯的程度
    private static let bend: CGFloat = 3
}
