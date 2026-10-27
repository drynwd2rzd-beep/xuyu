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
        run(Self.responders(for: text, convo: convo, members: members), in: convo, members: members, context: context)
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
        tasks[convo.id]?.cancel()
    }

    /// 群聊：@ 了谁就只让谁回复；否则所有成员依次回复
    static func responders(for text: String, convo: Conversation, members: [Persona]) -> [Persona] {
        guard convo.isGroup else { return Array(members.prefix(1)) }
        let mentioned = members.filter { text.contains("@\($0.name)") }
        return mentioned.isEmpty ? members : mentioned
    }

    private func run(_ responders: [Persona], in convo: Conversation, members: [Persona], context: ModelContext) {
        let convoID = convo.id
        guard !responders.isEmpty, !busy.contains(convoID) else { return }
        busy.insert(convoID)
        tasks[convoID] = Task { [weak self] in
            for persona in responders {
                guard let self, !Task.isCancelled else { break }
                await self.reply(as: persona, in: convo, members: members, context: context)
            }
            self?.busy.remove(convoID)
            self?.typing[convoID] = nil
            self?.tasks[convoID] = nil
        }
    }

    private func reply(as persona: Persona, in convo: Conversation, members: [Persona], context: ModelContext) async {
        let history = convo.visibleMessages()
        let message = Message(role: .assistant, content: "", personaID: persona.id)
        message.status = .streaming
        message.conversation = convo
        context.insert(message)
        let buffer = StreamBuffer()
        buffers[message.id] = buffer
        typing[convo.id] = persona.id

        do {
            guard let relay else { throw RelayError.notConfigured }
            let request = PromptBuilder.request(for: persona, convo: convo, members: members, history: history)
            message.modelLabel = request.model
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
                }
            }
            buffer.text += pendingText
            buffer.reasoning += pendingReasoning
            if buffer.text.trimmed.isEmpty && !Task.isCancelled { throw RelayError.server("没有收到回复。") }
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
            // 像真人一样，把短的几段拆成几条消息
            let parts = Self.split(message.content)
            if parts.count > 1 {
                message.content = parts[0]
                for (offset, part) in parts.dropFirst().enumerated() {
                    let extra = Message(role: .assistant, content: part, personaID: persona.id)
                    extra.modelLabel = message.modelLabel
                    extra.createdAt = message.createdAt.addingTimeInterval(Double(offset + 1) * 0.001)
                    extra.conversation = convo
                    context.insert(extra)
                }
            }
            notifyIfHidden(convo: convo, persona: persona, text: parts.last ?? message.content)
        }
        convo.updatedAt = .now
        if router?.openConversation == convo.id { convo.lastReadAt = .now }
        try? context.save()
    }

    private func notifyIfHidden(convo: Conversation, persona: Persona, text: String) {
        guard router?.openConversation != convo.id else { return }
        banners?.show(.init(conversationID: convo.id,
                            title: convo.isGroup ? "\(convo.title.isEmpty ? "群聊" : convo.title) · \(persona.name)" : persona.name,
                            body: text, tint: persona.tint, initial: persona.initial))
    }

    /// 短小、没有格式的多段回复拆成多条消息
    static func split(_ text: String) -> [String] {
        let markers = ["```", "\n#", "\n- ", "\n* ", "\n1. ", "|", "\n> "]
        if text.hasPrefix("#") || markers.contains(where: { text.contains($0) }) { return [text] }
        let parts = text.components(separatedBy: "\n\n").map(\.trimmed).filter { !$0.isEmpty }
        guard parts.count > 1, parts.count <= 5, parts.allSatisfy({ $0.count <= 90 }) else { return [text] }
        return parts
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
        parts.append("现在是 \(Fmt.full.string(from: .now))。")
        return parts.joined(separator: "\n\n")
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
        return "[\(Fmt.hm.string(from: m.createdAt))] \(who)：\(body)"
    }

    static func transcript(_ messages: [Message], names: [UUID: String], limit: Int = 40) -> String {
        var lines: [String] = []
        var lastDay: Date?
        for m in messages.suffix(limit) where m.status != .error {
            let day = m.createdAt.startOfDay
            if day != lastDay {
                lines.append("— \(Fmt.md.string(from: m.createdAt)) —")
                lastDay = day
            }
            lines.append(line(for: m, names: names))
        }
        return lines.joined(separator: "\n")
    }

    static func request(for persona: Persona, convo: Conversation, members: [Persona], history: [Message]) -> RelayRequest {
        let names = Dictionary(members.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let prompt = """
        下面是你们最近的聊天记录：

        \(transcript(history, names: names))

        请以「\(persona.name)」的身份回复。直接输出要说的话，不要加名字或时间。
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
        return RelayRequest(engine: persona.engine.rawValue, model: model(for: persona),
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
