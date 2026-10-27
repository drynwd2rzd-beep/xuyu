import SwiftUI
import UIKit
import QuickLook

struct MessageActions {
    var copy: (String) -> Void
    var select: (Message) -> Void
    var toggle: (Message) -> Void
    var delete: (Message) -> Void
    var regenerate: (Message) -> Void
    var addTodo: (String) -> Void
    var openImages: ([Attachment], Int) -> Void
    var retry: (Message) -> Void
    var quote: (Message) -> Void
    var recall: (Message) -> Void
    /// 点引用：跳到被引用的原文
    var openQuote: (Message) -> Void
    /// 长按「选择文字」：可以框选其中一部分
    var selectText: (String) -> Void
    var edit: (Message) -> Void
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
    @AppStorage(Prefs.showEngineLogo) private var showEngineLogo = true
    @State private var reasoningOpen = false
    @State private var detailHeight: CGFloat = 0

    private var live: StreamBuffer? { engine.buffers[message.id] }
    private var text: String { live?.text ?? message.content }
    private var reasoning: String { live?.reasoning ?? message.reasoning }
    /// 工作模式做过的步骤
    private var steps: [String] {
        live?.steps ?? message.steps.split(separator: "\n").map(String.init)
    }
    /// 名字旁有没有可以展开的内容（工作过程或思考过程）
    private var hasDetail: Bool { !steps.isEmpty || !reasoning.isEmpty }
    private var time: String { Fmt.bubble.string(from: message.createdAt) }
    /// 已经开始回复、但还没有出字
    private var isThinking: Bool { live != nil && (text.isEmpty || live?.hold == true) }

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
                if !message.quote.isEmpty { QuoteChip(text: message.quote).onTapGesture { actions.openQuote(message) } }
            }
            UserAvatar(size: 34).opacity(first ? 1 : 0)
        }
    }

    // MARK: - AI

    private var assistantSide: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(persona: persona, size: 34, ring: true).opacity(first ? 1 : 0)
            VStack(alignment: .leading, spacing: 5) {
                if first || isThinking || !steps.isEmpty { label }
                if hasDetail {
                    // 展开 / 收起：高度从 0 平滑长出来（或缩回去），下面的消息被柔和地推开，不会跳
                    detail
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailHeight = $0 }
                        .frame(height: reasoningOpen ? detailHeight : 0, alignment: .top)
                        .clipped()
                        .opacity(reasoningOpen ? 1 : 0)
                        // 收起时不占 VStack 的间距
                        .padding(.bottom, reasoningOpen ? 0 : -5)
                }
                content(isUser: false)
                    .animation(Motion.spring, value: isThinking)
                // TA 引用了你说过的话
                if !message.quote.isEmpty { QuoteChip(text: message.quote).onTapGesture { actions.openQuote(message) } }
                if message.status == .error { errorLine }
            }
            Spacer(minLength: 28)
        }
    }

    /// 消息上方：模型图标 + 名字；有工作过程或思考过程时旁边有个小箭头，点一下展开
    private var label: some View {
        Button {
            guard hasDetail else { return }
            withAnimation(.spring(duration: 0.45, bounce: 0.05)) { reasoningOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                if showEngineLogo { EngineLogo(engine: persona?.engine ?? .claude, size: 14) }
                Text(persona?.name ?? "已删除的角色").font(Typo.serif(12.5)).foregroundStyle(Palette.ink2)
                if hasDetail {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Palette.inkSoft)
                        .rotationEffect(.degrees(reasoningOpen ? 180 : 0))
                }
                // 正在干活时，名字旁淡淡地显示当前这一步
                if live != nil, !reasoningOpen, let current = steps.last {
                    Text(current)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.inkSoft)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(Motion.snappy, value: current)
                }
            }
            .padding(.leading, 2)
        }
        .buttonStyle(.plain)
        .disabled(selecting)
    }

    /// 展开后：一步步的工作过程，下面是思考过程
    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !steps.isEmpty {
                Text("工作过程 · \(steps.count) 步").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.inkSoft)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(live != nil && index == steps.count - 1 ? Palette.ink : Palette.faint)
                            .frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        Text(step)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink2)
                            .lineLimit(3)
                    }
                    // 展开时一条接一条依次淡入
                    .opacity(reasoningOpen ? 1 : 0)
                    .offset(y: reasoningOpen ? 0 : -4)
                    .animation(.spring(duration: 0.4, bounce: 0).delay(reasoningOpen ? Double(min(index, 12)) * 0.035 : 0),
                               value: reasoningOpen)
                }
            }
            if !reasoning.isEmpty {
                Text(reasoning)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(Palette.inkSoft)
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.hairline).frame(width: 2) }
        .padding(.leading, 2)
        .padding(.vertical, 2)
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(isUser: Bool) -> some View {
        switch message.kind {
        case .text:
            if isThinking {
                // 还没出字：一个气泡，里面三个点轮流跳
                TypingDots().transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
            } else if !text.isEmpty {
                bubble(isUser: isUser) {
                    if !isUser && MarkdownParser.looksRich(text) {
                        VStack(alignment: .trailing, spacing: 2) {
                            MarkdownView(text: text, fontSize: 15.5)
                            timeLabel
                        }
                    } else {
                        TimedText(text: text, time: time, read: isUser && message.readAt != nil)
                    }
                }
            }
        case .images:
            ImageStack(attachments: message.sortedAttachments) { actions.openImages(message.sortedAttachments, $0) }
                .contextMenu { menu }
            if !message.content.isEmpty {
                bubble(isUser: isUser) { TimedText(text: message.content, time: time, read: isUser && message.readAt != nil) }
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
                FileCard(name: a.fileName, size: a.data.count, time: time, data: a.data).contextMenu { menu }
            }
            if !message.content.isEmpty {
                bubble(isUser: isUser) { TimedText(text: message.content, time: time, read: isUser && message.readAt != nil) }
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
        Text(time).font(TimedText.stampFont).foregroundStyle(TimedText.stampColor)
    }

    @ViewBuilder
    private var menu: some View {
        Button { actions.quote(message) } label: { Label("引用", systemImage: "quote.bubble") }
        if !message.content.isEmpty {
            Button { actions.copy(message.content) } label: { Label("复制", systemImage: "doc.on.doc") }
            Button { actions.selectText(message.content) } label: { Label("选择文字", systemImage: "selection.pin.in.out") }
        }
        if message.role == .user {
            if message.kind == .text {
                Button { actions.edit(message) } label: { Label("编辑", systemImage: "pencil") }
            }
            Button { actions.recall(message) } label: { Label("撤回", systemImage: "arrow.uturn.backward") }
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
