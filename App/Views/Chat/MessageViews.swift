import SwiftUI
import UIKit

struct MessageActions {
    var copy: (String) -> Void
    var select: (Message) -> Void
    var toggle: (Message) -> Void
    var delete: (Message) -> Void
    var regenerate: (Message) -> Void
    var addTodo: (String) -> Void
    var openImages: ([Attachment], Int) -> Void
    var retry: (Message) -> Void
}

struct MessageRow: View {
    let message: Message
    let persona: Persona?
    let isGroup: Bool
    let first: Bool
    let selecting: Bool
    let picked: Bool
    let actions: MessageActions
    @Environment(ChatEngine.self) private var engine
    @AppStorage(Prefs.showReasoning) private var showReasoning = true
    @State private var reasoningOpen = false

    private var live: StreamBuffer? { engine.buffers[message.id] }
    private var text: String { live?.text ?? message.content }
    private var reasoning: String { live?.reasoning ?? message.reasoning }
    private var time: String { Fmt.hm.string(from: message.createdAt) }
    /// 已经开始回复、但还没有出字
    private var isThinking: Bool { live != nil && text.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if selecting {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(picked ? Palette.ink : Palette.faint)
                    .padding(.top, message.role == .assistant && first ? 26 : 6)
                    .frame(width: 32, alignment: .leading)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            if message.role == .user { userSide } else { assistantSide }
        }
        .contentShape(Rectangle())
        .onTapGesture { if selecting { actions.toggle(message) } }
        .animation(Motion.spring, value: selecting)
    }

    // MARK: - 用户

    private var userSide: some View {
        HStack(alignment: .top, spacing: Space.tight) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                content(isUser: true)
            }
            UserAvatar(size: 34).opacity(first ? 1 : 0)
        }
    }

    // MARK: - AI

    private var assistantSide: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(persona: persona, size: 34, ring: true).opacity(first ? 1 : 0)
            VStack(alignment: .leading, spacing: 5) {
                if first || isThinking { label }
                if reasoningOpen && !reasoning.isEmpty {
                    Text(reasoning)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .foregroundStyle(Palette.inkSoft)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(Palette.hairline).frame(width: 2) }
                        .padding(.leading, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                content(isUser: false)
                if message.status == .error { errorLine }
            }
            Spacer(minLength: 28)
        }
    }

    /// 消息上方：模型图标 + 名字，点一下展开思考过程
    private var label: some View {
        Button {
            guard !reasoning.isEmpty, showReasoning else { return }
            withAnimation(Motion.spring) { reasoningOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                // 回复还没出字时，标志慢慢转动
                TimelineView(.animation(paused: !isThinking)) { ctx in
                    EngineLogo(engine: persona?.engine ?? .claude, size: 14)
                        .rotationEffect(.degrees(isThinking ? ctx.date.timeIntervalSinceReferenceDate * 90 : 0))
                }
                Text(persona?.name ?? "已删除的角色").font(Typo.serif(12.5)).foregroundStyle(Palette.ink2)
                if isThinking {
                    Text(reasoning.isEmpty ? "正在输入…" : "正在思考…")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.inkSoft)
                        .transition(.opacity)
                }
                if !reasoning.isEmpty && showReasoning {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Palette.inkSoft)
                        .rotationEffect(.degrees(reasoningOpen ? 180 : 0))
                }
            }
            .photoChip()
            .padding(.leading, 2)
        }
        .buttonStyle(.plain)
        .disabled(selecting)
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(isUser: Bool) -> some View {
        switch message.kind {
        case .text:
            if !text.isEmpty {
                bubble(isUser: isUser) {
                    if !isUser && MarkdownParser.looksRich(text) {
                        VStack(alignment: .trailing, spacing: 2) {
                            MarkdownView(text: text, fontSize: 15.5)
                            timeLabel
                        }
                    } else {
                        TimedText(text: text, time: time)
                    }
                }
            }
        case .images:
            ImageStack(attachments: message.sortedAttachments) { actions.openImages(message.sortedAttachments, $0) }
                .contextMenu { menu }
            if !message.content.isEmpty {
                bubble(isUser: isUser) { TimedText(text: message.content, time: time) }
            }
        case .sticker:
            if let a = message.sortedAttachments.first, let image = cachedImage(a.data, key: a.id.uuidString) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 120, maxHeight: 120)
                    .contextMenu { menu }
            }
        case .note:
            NoteCard(text: message.content, time: time).contextMenu { menu }
        case .file:
            ForEach(message.sortedAttachments) { a in
                FileCard(name: a.fileName, size: a.data.count, time: time).contextMenu { menu }
            }
        }
    }

    private func bubble<C: View>(isUser: Bool, @ViewBuilder _ inner: () -> C) -> some View {
        inner()
            .padding(.horizontal, 13)
            .padding(.top, 9)
            .padding(.bottom, 7)
            .background(isUser ? Palette.userBubble.opacity(0.94) : Palette.botBubble.opacity(0.9),
                        in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
            .overlay {
                if !isUser {
                    RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous).strokeBorder(Palette.hairline.opacity(0.9), lineWidth: 0.5)
                }
            }
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
            .contextMenu { menu }
    }

    private var timeLabel: some View {
        Text(time).font(.system(size: 10.5)).foregroundStyle(Palette.inkSoft)
    }

    @ViewBuilder
    private var menu: some View {
        if !message.content.isEmpty {
            Button { actions.copy(message.content) } label: { Label("复制", systemImage: "doc.on.doc") }
        }
        Button { actions.select(message) } label: { Label("多选", systemImage: "checkmark.circle") }
        if message.role == .assistant && message.kind == .text {
            Button { actions.regenerate(message) } label: { Label("重新生成", systemImage: "arrow.clockwise") }
        }
        if !message.content.isEmpty {
            Button { actions.addTodo(message.content) } label: { Label("加入待办", systemImage: "checklist") }
        }
        Divider()
        Button(role: .destructive) { actions.delete(message) } label: { Label("删除", systemImage: "trash") }
    }

    private var errorLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 13))
            Text(message.errorText ?? "出错了").font(.system(size: 13)).lineLimit(3)
            Button("重试") { actions.retry(message) }.font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Palette.danger)
        .padding(.leading, 4)
    }

}

/// 时间放在气泡右下角：先留出时间的位置，再把时间叠上去
struct TimedText: View {
    let text: String
    let time: String
    var fontSize: CGFloat = 15.5

    var body: some View {
        (Text(text) + Text("   " + time).font(.system(size: 10.5)).foregroundColor(.clear))
            .font(.system(size: fontSize))
            .lineSpacing(3)
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .bottomTrailing) {
                Text(time).font(.system(size: 10.5)).foregroundStyle(Palette.inkSoft).offset(y: 1)
            }
            .textSelection(.disabled)
    }
}

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Palette.inkSoft)
                        .frame(width: 7, height: 7)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 4.5 - Double(i) * 0.75)))
                }
            }
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, 14)
        .background(Palette.botBubble.opacity(0.9), in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
        .accessibilityLabel("正在输入")
    }
}

/// 多张照片：叠成一摞，左右滑动切换
struct ImageStack: View {
    let attachments: [Attachment]
    let onOpen: (Int) -> Void
    @State private var top = 0
    @State private var drag: CGFloat = 0

    private let side: CGFloat = 188

    var body: some View {
        let count = attachments.count
        // 拖动进度：下面那张会随之慢慢升上来
        let progress = min(abs(drag) / 150, 1)
        ZStack {
            ForEach(Array(attachments.enumerated()), id: \.element.id) { index, a in
                let pos = (index - top + count) % count
                if pos < 3 || pos == count - 1 {
                    let layer = pos == count - 1 && count > 3 ? 2 : pos
                    card(a)
                        .scaleEffect(layer == 0 ? 1 - progress * 0.04 : (layer == 1 ? 0.97 + progress * 0.03 : 0.95))
                        .rotationEffect(.degrees(layer == 0 ? Double(drag / 24)
                                                 : (layer == 1 ? 5 * Double(1 - progress) : -5)))
                        .offset(x: layer == 0 ? drag : (layer == 1 ? 10 * (1 - progress) : -9),
                                y: layer == 0 ? 0 : (layer == 1 ? -9 * (1 - progress) : -12))
                        .zIndex(Double(3 - layer))
                }
            }
            if count > 1 {
                Text("\(top + 1) / \(count)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: Capsule())
                    .frame(width: side, height: side, alignment: .topTrailing)
                    .padding(10)
                    .frame(width: side, height: side, alignment: .topTrailing)
                    .zIndex(9)
                    .contentTransition(.numericText())
            }
        }
        .frame(width: side, height: side)
        .padding(.top, count > 1 ? 12 : 0)
        .padding(.trailing, count > 1 ? 10 : 0)
        .contentShape(Rectangle())
        .onTapGesture { onOpen(top) }
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard count > 1, abs(value.translation.width) > abs(value.translation.height) else { return }
                    drag = value.translation.width
                }
                .onEnded { value in
                    guard count > 1 else { return }
                    let dx = value.translation.width
                    let flick = abs(value.predictedEndTranslation.width) > 180
                    if abs(dx) > 50 || flick {
                        // 同一个弹簧动画里：最上面那张顺着方向塞到最底下，下一张升上来
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                            top = dx < 0 ? (top + 1) % count : (top - 1 + count) % count
                            drag = 0
                        }
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { drag = 0 }
                    }
                }
        )
        .sensoryFeedback(.selection, trigger: top)
        .accessibilityLabel("\(count) 张照片")
    }

    private func card(_ a: Attachment) -> some View {
        Group {
            if let image = cachedImage(a.data, key: a.id.uuidString) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Palette.fill
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous).strokeBorder(.white, lineWidth: 3))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
    }
}

struct NoteCard: View {
    let text: String
    let time: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Label("想法", systemImage: "pencil.line")
                .font(Typo.serif(13))
                .foregroundStyle(Palette.inkSoft)
            Text(text)
                .font(Typo.serif(16))
                .lineSpacing(5)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(time).font(.system(size: 10.5)).foregroundStyle(Palette.inkSoft)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(Space.card)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.clay.opacity(0.5)).frame(height: 3)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: Radius.tile, topTrailingRadius: Radius.tile, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }
}

struct FileCard: View {
    let name: String
    let size: Int
    let time: String

    var body: some View {
        HStack(spacing: Space.item) {
            Image(systemName: "doc.text")
                .font(.system(size: 20))
                .foregroundStyle(Palette.ink)
                .frame(width: 42, height: 42)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 15)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + " · " + time)
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
            }
        }
        .padding(Space.item)
        .frame(maxWidth: 250, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }
}
