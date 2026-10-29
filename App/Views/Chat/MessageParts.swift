import SwiftUI
import UIKit
import QuickLook

/// 引用的那句话：小小的一块，放在自己的消息下面（和微信一样）
struct QuoteChip: View {
    let text: String
    var onClose: (() -> Void)? = nil

    var body: some View {
        // 像 iMessage 的引用回复：左边一条细竖线，旁边浅灰小字，轻轻的不抢眼
        HStack(alignment: .center, spacing: 8) {
            Capsule()
                .fill(Palette.faint.opacity(0.7))
                .frame(width: 2.5)
            Text(text)
                .font(.system(size: Typo.secondary))
                .lineSpacing(2)
                .foregroundStyle(Palette.inkSoft)
                .lineLimit(2)
            if let onClose {
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.inkSoft)
                        .frame(width: 20, height: 20)
                        .background(Palette.fill, in: Circle())
                }
                .accessibilityLabel("取消引用")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 9)
        .padding(.trailing, onClose == nil ? 11 : 6)
        .padding(.vertical, 7)
        .background(Palette.card.opacity(0.72), in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous).strokeBorder(Palette.hairline.opacity(0.7), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
    }
}

/// 时间放在气泡右下角：先留出时间的位置，再把时间叠上去。气泡发出后大小不再变
struct TimedText: View {
    let text: String
    let time: String
    var fontSize: CGFloat = Typo.body

    var body: some View {
        (Text(text) + reserve)
            .font(.system(size: fontSize))
            .lineSpacing(3)
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .bottomTrailing) {
                Text(time).font(Self.stampFont).foregroundStyle(Self.stampColor).offset(y: 1)
            }
            .textSelection(.disabled)
    }

    /// 末行留给时间的透明占位：用同样的字排出来，宽度和右下角真正显示的一样，文字不会压到时间上。
    /// 用不换行空格，时间不会被拆到两行
    private var reserve: Text {
        Text("\u{00A0}\u{00A0}" + time.replacingOccurrences(of: " ", with: "\u{00A0}"))
            .font(Self.stampFont)
            .foregroundColor(.clear)
    }

    /// 气泡里的时间：小一点、数字等宽、颜色淡一点，更精致
    static let stampFont = Font.system(size: 9.5, weight: .medium).monospacedDigit()
    static let stampColor = Palette.inkSoft.opacity(0.8)
}

/// 工作模式里 AI 想运行命令、打开网页时，挂在 TA 这条消息下面的确认：说清楚要做什么，两个按钮。
/// 和翻译、转文字那种浅色小卡片同一个样子；点了以后就收起
struct ApprovalCard: View {
    let text: String
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(Palette.ink2)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.tight) {
                Spacer(minLength: 0)
                choice("不允许", filled: false) { onAnswer(false) }
                choice("允许", filled: true) { onAnswer(true) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.card.opacity(0.72), in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous).strokeBorder(Palette.hairline.opacity(0.7), lineWidth: 0.5))
        .sensoryFeedback(.warning, trigger: text)
    }

    private func choice(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(filled ? Palette.inkInverse : Palette.ink)
                .padding(.horizontal, Space.card)
                .frame(height: 34)
                .background {
                    if filled { Capsule().fill(Palette.ink) } else { Capsule().strokeBorder(Palette.hairline, lineWidth: 1) }
                }
                // 看起来 34 高，能点的范围够 44
                .contentShape(Capsule().inset(by: -5))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

/// 已读：像 iMessage 一样，一行小字放在你最后一条消息下面；TA 开始回复后就不再显示
struct ReadReceipt: View {
    var body: some View {
        Text("已读")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(TimedText.stampColor)
            .frame(maxWidth: .infinity, alignment: .trailing)
            // 和你的气泡右边对齐（让出头像的位置）
            .padding(.trailing, 34 + Space.tight + 4)
            .padding(.top, 5)
            .transition(.opacity.combined(with: .offset(y: -3)))
    }
}

/// 撤回的消息：中间一行浅灰色小字；你撤回的文字可以点「重新编辑」放回输入框
struct RecalledLine: View {
    let message: Message
    let onEdit: (Message) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("你撤回了一条消息").font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
            if message.kind == .text, !message.content.isEmpty, Date.now.timeIntervalSince(message.createdAt) < 600 {
                Button("重新编辑") { onEdit(message) }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

/// 拍一拍：和撤回一样是中间一行浅灰色小字。你拍的写「你拍了拍 Claude」，TA 拍你写「Claude 拍了拍你」
struct NudgeLine: View {
    let message: Message
    /// 拍你的那位角色的名字（你拍别人时不用）
    let name: String

    var body: some View {
        Text(message.role == .user ? "你拍了拍\(message.content)" : "\(name) 拍了拍你")
            .font(.system(size: 12))
            .foregroundStyle(Palette.inkSoft)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .transition(.opacity)
    }
}

extension AnyTransition {
    /// 小点变成文字时，带字的气泡出现的样子：从自己那一边的下角以最终大小轻轻弹出（和新消息冒出来同一条曲线）
    static func bubblePop(anchor: UnitPoint) -> AnyTransition {
        let pop: AnyTransition = Motion.reduced ? .opacity : .scale(scale: 0.85, anchor: anchor).combined(with: .opacity)
        return .asymmetric(insertion: pop.animation(Motion.bubblePop), removal: .opacity.animation(Motion.fade))
    }
}

struct TypingDots: View {
    /// 只要三个点，不要外面的气泡（放进已有的气泡里）
    var bare = false

    var body: some View {
        if bare { dots } else {
            dots
                .padding(.horizontal, Space.card)
                .padding(.vertical, 9)
                .background(Palette.botBubble.opacity(0.9), in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
        }
    }

    private var dots: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    // 每个点依次轻轻跳起再落下，像 iMessage 那样
                    let phase = (t * 1.4 - Double(i) * 0.18).truncatingRemainder(dividingBy: 1)
                    let lift = phase < 0.45 ? sin(phase / 0.45 * .pi) : 0
                    Circle()
                        .fill(Palette.inkSoft)
                        .frame(width: 7, height: 7)
                        .offset(y: -1.8 * lift)
                        .opacity(0.4 + 0.6 * lift)
                }
            }
            .frame(height: 20)
        }
        .accessibilityLabel("正在输入")
    }
}
