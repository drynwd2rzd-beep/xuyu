import Foundation
import SwiftData
import Observation
import UIKit

/// 正在生成中的消息。单独成对象，流式刷新时只重绘这一条。
@Observable
final class StreamBuffer {
    var text = ""
    var reasoning = ""
}

struct OutgoingAttachment {
    var kind: String
    var name: String
    var data: Data
}

@MainActor
@Observable
final class ChatEngine {
    private(set) var buffers: [UUID: StreamBuffer] = [:]
    /// 对话 ID -> 正在回复的角色 ID
    private(set) var typing: [UUID: UUID] = [:]
    private(set) var busy: Set<UUID> = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// 回复途中用户又发了消息：等这一轮说完（或直接打断）后，再按新的上下文回复
    @ObservationIgnored private var pending: [UUID: [Persona]] = [:]
    /// 这一轮回复是不是已经开始出字了
    @ObservationIgnored private var speaking: Set<UUID> = []
    /// 切到后台时向系统多要一点时间，让正在进行的回复写完
    @ObservationIgnored private var background: [UUID: UIBackgroundTaskIdentifier] = [:]
    @ObservationIgnored private weak var relay: RelayClient?
    @ObservationIgnored private weak var banners: BannerCenter?
    @ObservationIgnored private weak var router: Router?

    func attach(relay: RelayClient, banners: BannerCenter, router: Router) {
        self.relay = relay
        self.banners = banners
        self.router = router
    }

    func isBusy(_ convo: Conversation) -> Bool { busy.contains(convo.id) }

    // MARK: - 发送

    func send(_ text: String, kind: MessageKind = .text, attachments: [OutgoingAttachment] = [],
              in convo: Conversation, members: [Persona], context: ModelContext) {
        let message = Message(role: .user, kind: kind, content: text)
        message.conversation = convo
        context.insert(message)
        for (index, item) in attachments.enumerated() {
            let a = Attachment(kind: item.kind, fileName: item.name, data: item.data, order: index)
            a.message = message
            context.insert(a)
        }
        convo.updatedAt = .now
        convo.lastReadAt = .now
        Companion.cancelPlannedMessages(in: convo, context: context)
        try? context.save()
        let responders = Self.responders(for: text, convo: convo, members: members)
        if busy.contains(convo.id) {
            // 像真人聊天一样可以连着发：对方还没开口就重新想；已经在说了，就说完这句再接着回
            pending[convo.id] = responders
            if !speaking.contains(convo.id) { tasks[convo.id]?.cancel() }
            return
        }
        run(responders, in: convo, members: members, context: context)
    }

    func regenerate(_ message: Message, in convo: Conversation, members: [Persona], context: ModelContext) {
        guard !isBusy(convo), message.role == .assistant else { return }
        let persona = members.first { $0.id == message.personaID } ?? (convo.isGroup ? nil : members.first)
        context.delete(message)
        try? context.save()
        guard let persona else { return }
        run([persona], in: convo, members: members, context: context)
    }

    func stop(_ convo: Conversation) {
        pending[convo.id] = nil
        tasks[convo.id]?.cancel()
    }

    /// 群聊：@ 了谁就只让谁回复；@所有人 或没有 @ 时所有成员依次回复
    static func responders(for text: String, convo: Conversation, members: [Persona]) -> [Persona] {
        guard convo.isGroup else { return Array(members.prefix(1)) }
        if text.contains("@所有人") { return members }
        let mentioned = members.filter { text.contains("@\($0.name)") }
        return mentioned.isEmpty ? members : mentioned
    }

    private func run(_ responders: [Persona], in convo: Conversation, members: [Persona], context: ModelContext) {
        let convoID = convo.id
        guard !responders.isEmpty, !busy.contains(convoID) else { return }
        busy.insert(convoID)
        holdBackground(convoID)
        // 群聊可以设置自动讨论几轮：第一轮按 @ 回复，之后大家接着彼此的话说
        let rounds = convo.isGroup ? max(1, convo.discussRounds) : 1
        tasks[convoID] = Task { [weak self] in
            rounds: for round in 0..<rounds {
                for persona in round == 0 ? responders : members {
                    guard let self, !Task.isCancelled, self.pending[convoID] == nil else { break rounds }
                    await self.reply(as: persona, in: convo, members: members, context: context, discussing: round > 0)
                }
            }
            guard let self else { return }
            self.busy.remove(convoID)
            self.speaking.remove(convoID)
            self.typing[convoID] = nil
            self.tasks[convoID] = nil
            if let next = self.pending.removeValue(forKey: convoID) {
                // 回复途中你又说了话：接着按最新的聊天回复
                self.run(next, in: convo, members: members, context: context)
                return
            }
            self.releaseBackground(convoID)
            // 聊得够多了，就在后台把更早的部分整理进长期记忆
            if let relay = self.relay {
                Task { await Memory.updateIfNeeded(convo, members: members, context: context, relay: relay) }
            }
        }
    }

    private func holdBackground(_ id: UUID) {
        guard background[id] == nil else { return }
        background[id] = UIApplication.shared.beginBackgroundTask(withName: "reply") { [weak self] in
            Task { @MainActor in self?.releaseBackground(id) }
        }
    }

    private func releaseBackground(_ id: UUID) {
        guard let task = background.removeValue(forKey: id), task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
    }

    private func newBubble(_ persona: Persona, in convo: Conversation, context: ModelContext, label: String) -> (Message, StreamBuffer) {
        let message = Message(role: .assistant, content: "", personaID: persona.id)
        message.status = .streaming
        message.modelLabel = label
        message.conversation = convo
        context.insert(message)
        let buffer = StreamBuffer()
        buffers[message.id] = buffer
        return (message, buffer)
    }

    private func reply(as persona: Persona, in convo: Conversation, members: [Persona], context: ModelContext,
                       discussing: Bool = false) async {
        let history = convo.visibleMessages()
        let request = PromptBuilder.request(for: persona, convo: convo, members: members, history: history, discussing: discussing)
        var (message, buffer) = newBubble(persona, in: convo, context: context, label: request.model)
        var sent: [String] = []
        var rich = false
        typing[convo.id] = persona.id

        /// 像真人一样一句一句发：每说完一段（空一行），就把这段作为一条消息发出去，接着「输入中」
        func commitParagraphs() {
            while !rich, let range = buffer.text.range(of: "\n\n") {
                let head = String(buffer.text[..<range.lowerBound]).trimmed
                let rest = String(buffer.text[range.upperBound...])
                guard !head.isEmpty else { buffer.text = rest; continue }
                if Self.looksRich(head) { rich = true; return }
                message.content = head
                message.status = .done
                buffers[message.id] = nil
                sent.append(head)
                (message, buffer) = newBubble(persona, in: convo, context: context, label: request.model)
                buffer.text = rest
                try? context.save()
            }
        }

        do {
            guard let relay else { throw RelayError.notConfigured }
            var pendingText = ""
            var pendingReasoning = ""
            var lastFlush = ContinuousClock.now
            for try await event in relay.run(request) {
                switch event {
                case .text(let s): pendingText += s
                case .reasoning(let s): pendingReasoning += s
                }
                if ContinuousClock.now - lastFlush > .milliseconds(50) {
                    buffer.text += pendingText
                    buffer.reasoning += pendingReasoning
                    pendingText = ""
                    pendingReasoning = ""
                    lastFlush = .now
                    if !buffer.text.trimmed.isEmpty { speaking.insert(convo.id) }
                    if !rich && Self.looksRich(buffer.text) { rich = true }
                    commitParagraphs()
                }
            }
            buffer.text += pendingText
            buffer.reasoning += pendingReasoning
            commitParagraphs()
            if buffer.text.trimmed.isEmpty && sent.isEmpty && !Task.isCancelled { throw RelayError.server("没有收到回复。") }
            message.status = .done
        } catch {
            if Task.isCancelled || error is CancellationError {
                message.status = .done
            } else {
                message.status = .error
                message.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        buffers[message.id] = nil
        message.content = buffer.text.trimmed
        message.reasoning = buffer.reasoning.trimmed
        if message.status == .done && message.content.isEmpty {
            context.delete(message)
        } else if message.status == .done {
            sent.append(message.content)
        }
        if let last = sent.last {
            notify(convo: convo, persona: persona, text: last)
        }
        convo.updatedAt = .now
        if router?.openConversation == convo.id { convo.lastReadAt = .now }
        try? context.save()
    }

    /// 回复好了：在别的页面时顶部滑下提示；App 在后台时发系统通知
    private func notify(convo: Conversation, persona: Persona, text: String) {
        let title = convo.isGroup ? "\(convo.title.isEmpty ? "群聊" : convo.title) · \(persona.name)" : persona.name
        if UIApplication.shared.applicationState != .active {
            Reminders.notifyReply(conversationID: convo.id, title: title, body: text)
            return
        }
        guard router?.openConversation != convo.id else { return }
        banners?.show(.init(conversationID: convo.id, title: title, body: text, tint: persona.tint, initial: persona.initial))
    }

    /// 带格式（代码、列表、表格、标题、引用）的内容整段放在一个气泡里，不拆
    static func looksRich(_ text: String) -> Bool {
        let markers = ["```", "\n#", "\n- ", "\n* ", "\n1. ", "|", "\n> "]
        return text.hasPrefix("#") || text.hasPrefix("- ") || text.hasPrefix("1. ") || markers.contains { text.contains($0) }
    }
}

enum PromptBuilder {
    static var userName: String {
        let n = Prefs.nicknameValue
        return n.isEmpty ? "用户" : n
    }

    static func model(for persona: Persona) -> String {
        persona.model.isEmpty ? Prefs.defaultModel(for: persona.engine) : persona.model
    }

    static func effort(for persona: Persona) -> String {
        persona.effort.isEmpty ? Prefs.defaultEffort(for: persona.engine) : persona.effort
    }

    static func system(for persona: Persona, convo: Conversation?, members: [Persona]) -> String {
        var parts: [String] = []
        let base = persona.systemPrompt.trimmed
        parts.append(base.isEmpty ? "你是「\(persona.name)」。" : base)
        parts.append("""
        你在一个手机聊天 App 里和\(userName)聊天。像发消息一样自然、口语化地回复，不要长篇大论；想分几条说的时候用空行隔开，每段一两句话。只有内容复杂时才用 Markdown。
        """)
        if let convo, convo.isGroup {
            let others = members.filter { $0.id != persona.id }.map(\.name)
            let roster = (["\(userName)（用户）"] + others).joined(separator: "、")
            parts.append("""
            你正在群聊「\(convo.displayTitle(members))」里，你的名字是「\(persona.name)」。群成员：\(roster)。
            只以「\(persona.name)」的身份说话，不要替别人发言，不要在开头写自己的名字。
            """)
        }
        if let memory = convo?.memory.trimmed, !memory.isEmpty {
            parts.append("你记得的关于\(userName)、以及你们之间的事（来自更早的聊天）：\n\(memory)")
        }
        // 这里只写到「今天」：一整天内开头都不变，模型的提示缓存才能一直命中；具体时间放在消息末尾
        parts.append("今天是 \(Fmt.day.string(from: .now))。")
        return parts.joined(separator: "\n\n")
    }

    /// 还没总结进记忆、要逐条发给模型的那部分聊天
    static func recent(_ history: [Message], convo: Conversation) -> [Message] {
        Array(history.filter { $0.createdAt > convo.memoryUntil }.suffix(Memory.maxWindow))
    }

    static func line(for m: Message, names: [UUID: String]) -> String {
        let who = m.role == .user ? userName : (m.personaID.flatMap { names[$0] } ?? "AI")
        var body: String
        switch m.kind {
        case .text: body = m.content
        case .images: body = "[发了 \(m.attachments?.count ?? 0) 张图片]" + (m.content.isEmpty ? "" : " \(m.content)")
        case .file: body = "[发了文件：\(m.sortedAttachments.map(\.fileName).joined(separator: "、"))]"
        case .note: body = "【写下的想法】\(m.content)"
        case .sticker: body = "[发了一个表情]"
        }
        return "[\(Fmt.time24.string(from: m.createdAt))] \(who)：\(body)"
    }

    static func transcript(_ messages: [Message], names: [UUID: String]) -> String {
        var lines: [String] = []
        var lastDay: Date?
        for m in messages where m.status != .error {
            let day = m.createdAt.startOfDay
            if day != lastDay {
                lines.append("— \(Fmt.md.string(from: m.createdAt)) —")
                lastDay = day
            }
            lines.append(line(for: m, names: names))
        }
        return lines.joined(separator: "\n")
    }

    static func request(for persona: Persona, convo: Conversation, members: [Persona], history: [Message],
                        discussing: Bool = false) -> RelayRequest {
        let names = Dictionary(members.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let ask = discussing
            ? "大家正在讨论，请以「\(persona.name)」的身份接着说：可以回应其他人的观点、补充或提出不同看法，不要重复别人说过的。"
            : "请以「\(persona.name)」的身份回复。"
        let prompt = """
        下面是你们最近的聊天记录：

        \(transcript(recent(history, convo: convo), names: names))

        现在是 \(Fmt.time24.string(from: .now))。\(ask)直接输出要说的话，不要加名字或时间。
        """
        // 最后一次 AI 回复之后用户发的附件
        let lastAI = history.lastIndex { $0.role == .assistant } ?? -1
        var attachments: [RelayAttachment] = []
        for m in history.suffix(from: lastAI + 1) where m.role == .user {
            for a in m.sortedAttachments {
                attachments.append(RelayAttachment(kind: a.isImage ? "image" : "file",
                                                   name: a.fileName.isEmpty ? "image.jpg" : a.fileName,
                                                   data: a.data.base64EncodedString()))
            }
        }
        return RelayRequest(engine: persona.engine.rawValue, model: model(for: persona), effort: effort(for: persona),
                            system: system(for: persona, convo: convo, members: members),
                            prompt: prompt, attachments: attachments)
    }
}

enum ImageUtil {
    static func downscale(_ data: Data, maxSide: CGFloat = 1600, quality: CGFloat = 0.82) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.jpegData(withCompressionQuality: quality) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func sticker(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let side: CGFloat = 360
        let scale = min(1, side / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
