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
    @AppStorage(Prefs.showReasoning) private var showReasoning = true
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
    private var hasDetail: Bool { !steps.isEmpty || (!reasoning.isEmpty && showReasoning) }
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
                if !message.quote.isEmpty { QuoteChip(text: message.quote) }
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
                if !message.quote.isEmpty { QuoteChip(text: message.quote) }
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
            if !reasoning.isEmpty && showReasoning {
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

/// 引用的那句话：小小的一块，放在自己的消息下面（和微信一样）
struct QuoteChip: View {
    let text: String
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.inkSoft)
                .lineLimit(2)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Palette.faint)
                }
                .accessibilityLabel("取消引用")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.fill.opacity(0.85), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// 时间放在气泡右下角：先留出时间的位置，再把时间叠上去
struct TimedText: View {
    let text: String
    let time: String
    var fontSize: CGFloat = 15.5
    /// 你发的消息被 TA 看到了：时间后面显示已读双勾
    var read = false

    var body: some View {
        (Text(text) + Text("  " + time + (read ? "   " : "")).font(Self.stampFont).foregroundColor(.clear))
            .font(.system(size: fontSize))
            .lineSpacing(3)
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 3) {
                    Text(time).font(Self.stampFont).foregroundStyle(Self.stampColor)
                    if read { ReadTicks().transition(.opacity.combined(with: .scale(scale: 0.6))) }
                }
                .offset(y: 1)
                .animation(Motion.spring, value: read)
            }
            .textSelection(.disabled)
    }

    /// 气泡里的时间：小一点、数字等宽、颜色淡一点，更精致
    static let stampFont = Font.system(size: 9.5, weight: .medium).monospacedDigit()
    static let stampColor = Palette.inkSoft.opacity(0.8)
}

/// 已读：两个叠在一起的小勾
struct ReadTicks: View {
    var body: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark")
            Image(systemName: "checkmark").offset(x: 4.5)
        }
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(TimedText.stampColor)
        .frame(width: 13, alignment: .leading)
        .accessibilityLabel("已读")
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

struct TypingDots: View {
    var body: some View {
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
        .padding(.horizontal, Space.card)
        .padding(.vertical, 9)
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
                        withAnimation(Motion.settle) {
                            top = dx < 0 ? (top + 1) % count : (top - 1 + count) % count
                            drag = 0
                        }
                    } else {
                        withAnimation(Motion.settle) { drag = 0 }
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
            Text(time).font(TimedText.stampFont).foregroundStyle(TimedText.stampColor)
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
    /// 有文件内容时，点一下用系统预览打开（能保存到「文件」、分享给其他 App）
    var data: Data? = nil
    @State private var previewURL: URL?

    var body: some View {
        card
            .contentShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .onTapGesture { open() }
            .quickLookPreview($previewURL)
    }

    private func open() {
        guard let data else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name.isEmpty ? "文件" : name)
        try? data.write(to: url, options: .atomic)
        previewURL = url
    }

    private var card: some View {
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
