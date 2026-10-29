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
    /// 长按「正在输入」的气泡：让 TA 别回了
    var stop: () -> Void
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
    @Environment(\.modelContext) private var context
    @AppStorage(Prefs.showEngineLogo) private var showEngineLogo = true
    @State private var reasoningOpen = false
    @State private var detailHeight: CGFloat = 0
    /// 语音消息：长按「转文字」后在下面显示说的话
    @State private var transcript = false

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
    /// 这个对话里 TA 们还在回：这时不能重新生成 / 重试（菜单里不出现，「重试」变灰）
    private var replying: Bool { message.conversation.map { engine.busy.contains($0.id) } ?? false }
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
                translationView
            }
            UserAvatar(size: 34).opacity(first ? 1 : 0)
        }
    }

    // MARK: - AI

    private var assistantSide: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(persona: persona, size: 34, ring: true).opacity(first ? 1 : 0)
            VStack(alignment: .leading, spacing: 5) {
                // 名字只在 TA 这一串的第一条上面出现（像 iMessage）。以前「正在输入」时也总带着名字，
                // 连着发第二条时名字先冒出来、小点变成字时又消失，这一行忽高忽低，看起来像抽了一下
                if first || !steps.isEmpty { label }
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
                if let id = message.momentID { MomentRef(id: id) }
                content(isUser: false)
                    .animation(Motion.bubble, value: isThinking)
                // TA 引用了你说过的话
                if !message.quote.isEmpty { QuoteChip(text: message.quote).onTapGesture { actions.openQuote(message) } }
                translationView
                // 工作模式：AI 想运行命令、打开网页，等你点
                if let pending = live?.approval {
                    ApprovalCard(text: pending.text) { ok in engine.answer(message, ok: ok) }
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .topLeading)))
                }
                if message.status == .error { errorLine }
            }
            Spacer(minLength: 28)
        }
    }

    /// 翻译：翻好了显示在消息下面的浅色小卡片里；正在翻时显示「翻译中…」
    @ViewBuilder
    private var translationView: some View {
        if !message.translation.isEmpty {
            TranscriptCard(text: message.translation)
                .transition(.opacity.combined(with: .offset(y: -6)))
        } else if engine.translating.contains(message.id) {
            Text("翻译中…")
                .font(.system(size: Typo.secondary))
                .foregroundStyle(Palette.inkSoft)
                .padding(.horizontal, 6)
                .transition(.opacity)
        }
    }

    /// 消息上方：模型图标 + 名字；有工作过程或思考过程时旁边有个小箭头，点一下展开
    private var label: some View {
        Button {
            guard hasDetail else { return }
            withAnimation(Motion.spring) { reasoningOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                if showEngineLogo { EngineLogo(engine: persona?.engine ?? .claude, size: 14) }
                Text(persona?.name ?? "已删除的角色").font(Typo.serif(Typo.secondary)).foregroundStyle(Palette.ink2)
                if hasDetail {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Palette.inkSoft)
                        .rotationEffect(.degrees(reasoningOpen ? 180 : 0))
                }
                // 正在干活时，名字旁淡淡地显示当前这一步
                if live != nil, !reasoningOpen, let current = steps.last {
                    Text(current)
                        .font(.system(size: Typo.caption))
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
                Text("工作过程 · \(steps.count) 步").font(.system(size: Typo.caption, weight: .medium)).foregroundStyle(Palette.inkSoft)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(live != nil && index == steps.count - 1 ? Palette.ink : Palette.faint)
                            .frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        Text(step)
                            .font(.system(size: Typo.secondary))
                            .foregroundStyle(Palette.ink2)
                            .lineLimit(3)
                    }
                    // 展开时一条接一条依次淡入
                    .opacity(reasoningOpen ? 1 : 0)
                    .offset(y: reasoningOpen ? 0 : -4)
                    .animation(Motion.snappy.delay(reasoningOpen ? Double(min(index, 12)) * 0.035 : 0),
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
            if isThinking || !text.isEmpty {
                // 同一个气泡：还没出字时里面三个点轮流跳；这句打好了，小点淡出，气泡柔和地撑开，文字由虚变实浮现
                bubble(isUser: isUser) {
                    ZStack(alignment: .topLeading) {
                        if isThinking {
                            TypingDots(bare: true)
                                .transition(.opacity.animation(Motion.fade))
                        } else if !isUser && MarkdownParser.looksRich(text) {
                            VStack(alignment: .trailing, spacing: 2) {
                                MarkdownView(text: text, fontSize: Typo.body)
                                timeLabel
                            }
                            .transition(.reveal)
                        } else {
                            TimedText(text: text, time: time)
                                .transition(.reveal)
                        }
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
        case .voice:
            if let audio = message.sortedAttachments.first {
                bubble(isUser: isUser) {
                    VoiceBubble(id: message.id.uuidString, data: audio.data, time: time)
                }
                // 转文字：语音气泡不动，说的话在下面另起一张浅色小卡片
                if transcript {
                    TranscriptCard(text: message.content)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
        case .note:
            NoteCard(text: message.content, time: time).contextMenu { menu }
        case .file:
            ForEach(message.sortedAttachments) { a in
                FileCard(name: a.fileName, size: a.data.count, time: time, data: a.data).contextMenu { menu }
            }
            if !message.content.isEmpty {
                bubble(isUser: isUser) { TimedText(text: message.content, time: time) }
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

    /// 长按菜单。TA 正在打字或正在逐字说的这一条：只有一件事可做，让 TA 停下（不在聊天页多放按钮）
    @ViewBuilder
    private var menu: some View {
        if message.status == .streaming {
            Button { actions.stop() } label: { Label("停止回复", systemImage: "stop.circle") }
        } else {
            doneMenu
        }
    }

    @ViewBuilder
    private var doneMenu: some View {
        if message.kind == .voice {
            Button {
                // 等长按菜单完全收起再展开，两个动画不会撞在一起
                Task {
                    try? await Task.sleep(for: .milliseconds(380))
                    withAnimation(Motion.spring) { transcript.toggle() }
                }
            } label: {
                Label(transcript ? "收起文字" : "转文字", systemImage: "text.bubble")
            }
        }
        if !message.content.isEmpty && message.status == .done {
            if message.translation.isEmpty {
                Button {
                    Task { await engine.translate(message, context: context) }
                } label: { Label("翻译", systemImage: "character.bubble") }
            } else {
                Button {
                    // 等长按菜单收起再收起翻译，两个动画不撞在一起
                    Task {
                        try? await Task.sleep(for: .milliseconds(380))
                        engine.hideTranslation(message, context: context)
                    }
                } label: { Label("收起翻译", systemImage: "character.bubble") }
            }
        }
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
        if message.role == .assistant && message.kind == .text && !replying {
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
            Text(LocalizedStringKey(message.errorText ?? "出错了")).font(.system(size: 13)).lineLimit(3)
            Button { actions.retry(message) } label: {
                Text("重试")
                    .font(.system(size: 13, weight: .semibold))
                    // 字还是那么小，能点的范围扩到 44 高
                    .padding(.horizontal, Space.tight)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(replying)
            .opacity(replying ? 0.4 : 1)
            .padding(.vertical, -14)
        }
        .foregroundStyle(Palette.danger)
        .padding(.leading, 4)
    }

}
