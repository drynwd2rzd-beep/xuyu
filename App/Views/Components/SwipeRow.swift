import SwiftUI
import UIKit

struct SwipeAction {
    let icon: String
    let title: String
    let tint: Color
    let action: () -> Void
}

/// 列表行的左右滑动：右滑过阈值直接执行左侧动作（置顶），左滑露出右侧按钮（删除）
struct SwipeRow<Content: View>: View {
    let id: UUID
    @Binding var openID: UUID?
    var leading: SwipeAction?
    var trailing: SwipeAction?
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0
    @State private var start: CGFloat = 0
    @State private var armed = false
    private let reveal: CGFloat = 84
    private let trigger: CGFloat = 76

    var body: some View {
        content
            .background(Palette.card)
            .offset(x: offset)
            .background { actions }
            .clipped()
            .gesture(HorizontalPan(onChange: changed, onEnd: ended))
            .onChange(of: openID) { _, new in
                if new != id, offset != 0 { withAnimation(Motion.spring) { offset = 0 } }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: armed) { _, new in new }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if let leading, offset > 0 {
                button(leading, width: offset, alignment: .leading)
            }
            Spacer(minLength: 0)
            if let trailing, offset < 0 {
                button(trailing, width: -offset, alignment: .trailing)
            }
        }
    }

    private func button(_ a: SwipeAction, width: CGFloat, alignment: Alignment) -> some View {
        Button {
            withAnimation(Motion.spring) { offset = 0 }
            openID = nil
            a.action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: a.icon).font(.system(size: 17, weight: .medium))
                Text(a.title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Palette.inkInverse)
            .frame(width: reveal)
            .scaleEffect(min(1, width / reveal * 0.4 + 0.6))
            .opacity(min(1, width / (reveal * 0.6)))
            .frame(width: width, alignment: alignment == .leading ? .trailing : .leading)
            .frame(maxHeight: .infinity)
            .background(a.tint)
        }
        .buttonStyle(.plain)
    }

    private func changed(_ t: CGFloat) {
        if t != 0, openID != id { openID = id }
        var x = start + t
        if leading == nil { x = min(x, 0) }
        if trailing == nil { x = max(x, 0) }
        // 超出后加阻尼
        let limit = x > 0 ? trigger : reveal
        if abs(x) > limit { x = (x > 0 ? 1 : -1) * (limit + (abs(x) - limit) * 0.35) }
        offset = x
        armed = x >= trigger
    }

    private func ended(_ t: CGFloat, _ velocity: CGFloat) {
        let x = offset
        withAnimation(Motion.settle) {
            if x >= trigger || (x > 30 && velocity > 900) {
                offset = 0
                leading?.action()
            } else if x < -reveal * 0.5 || (x < -20 && velocity < -700) {
                offset = -reveal
            } else {
                offset = 0
            }
        }
        start = offset
        armed = false
        if offset == 0, openID == id { openID = nil }
    }
}

/// 只认横向拖动的手势，竖向滚动不受影响
struct HorizontalPan: UIGestureRecognizerRepresentable {
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let t = pan.translation(in: pan.view).x
        switch pan.state {
        case .changed: onChange(t)
        case .ended, .cancelled, .failed: onEnd(t, pan.velocity(in: pan.view).x)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.3
        }
    }
}
