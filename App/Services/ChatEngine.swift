import Foundation
import SwiftData
import Observation
import SwiftUI
import UIKit

/// 正在生成中的消息。单独成对象，流式刷新时只重绘这一条。
@Observable
final class StreamBuffer {
    var text = ""
    var reasoning = ""
    var steps: [String] = []
    /// 先不显示文字（只显示「正在输入」），等这一段写完再整条出现
    var hold = false
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

    func send(_ text: String, kind: MessageKind = .text, attachments: [OutgoingAttachment] = [], quote: String = "", quoteID: UUID? = nil,
              in convo: Conversation, members: [Persona], context: ModelContext) {
        let message = Message(role: .user, kind: kind, content: text)
        message.quote = quote
        message.quoteID = quoteID
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
        run(responders, in: convo, members: members, context: context, react: true)
    }

    /// 你撤回或编辑了消息：TA 还没开口就重新看一遍再回；已经在说了就算了
    func reconsider(_ convo: Conversation, members: [Persona], context: ModelContext) {
        guard busy.contains(convo.id), !speaking.contains(convo.id) else { return }
        let last = convo.visibleMessages().last { $0.role == .user && !$0.recalled }
        pending[convo.id] = Self.responders(for: last?.content ?? "", convo: convo, members: members)
        tasks[convo.id]?.cancel()
    }

    /// TA 开始看你的消息了：你发的消息显示已读双勾
    private func markRead(_ convo: Conversation, context: ModelContext) {
        let now = Date.now
        var changed = false
        for m in convo.messages ?? [] where m.role == .user && m.readAt == nil && m.createdAt <= now {
            m.readAt = now
            changed = true
        }
        if changed { try? context.save() }
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

    private func run(_ responders: [Persona], in convo: Conversation, members: [Persona], context: ModelContext,
                     react: Bool = false) {
        let convoID = convo.id
        guard !responders.isEmpty, !busy.contains(convoID) else { return }
        busy.insert(convoID)
        holdBackground(convoID)
        // 群聊可以设置自动讨论几轮：第一轮按 @ 回复，之后大家接着彼此的话说
        // 「偶尔」：大多数时候各回一次，有时会接着聊上两三轮，像真的群聊一样不固定
        let occasional = Double.random(in: 0..<1)
        let rounds = !convo.isGroup ? 1
            : convo.discussRounds < 0 ? (occasional < 0.6 ? 1 : occasional < 0.88 ? 2 : 3)
            : max(1, convo.discussRounds)
        tasks[convoID] = Task { [weak self] in
            // 像真人一样，看到消息后过一小会儿才开始回（每次不一样）；这期间你又发了，就一起看、一起回
            if react {
                // 先「已读」，过一会儿才开始打字
                try? await Task.sleep(for: .seconds(Double.random(in: 0.3...0.9)))
                if !Task.isCancelled { withAnimation(Motion.spring) { self?.markRead(convo, context: context) } }
                try? await Task.sleep(for: .seconds(Double.random(in: 0.4...1.8)))
            } else {
                self?.markRead(convo, context: context)
            }
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
                self.run(next, in: convo, members: members, context: context, react: true)
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

    private func newBubble(_ persona: Persona, in convo: Conversation, context: ModelContext, label: String,
                           relayID: String) -> (Message, StreamBuffer) {
        let message = Message(role: .assistant, content: "", personaID: persona.id)
        message.status = .streaming
        message.modelLabel = label
        message.relayID = relayID
        message.conversation = convo
        context.insert(message)
        let buffer = StreamBuffer()
        buffers[message.id] = buffer
        return (message, buffer)
    }

    private func reply(as persona: Persona, in convo: Conversation, members: [Persona], context: ModelContext,
                       discussing: Bool = false) async {
        let history = convo.visibleMessages()
        let request = PromptBuilder.request(for: persona, convo: convo, members: members, history: history, discussing: discussing,
                                            diaryNotes: Companion.myDiaryNotes(context: context),
                                            sharedMemory: sharedMemory(of: persona, besides: convo, context: context),
                                            stickerCategories: Self.stickerCategories(context: context))
        let relayID = UUID().uuidString
        var (message, buffer) = newBubble(persona, in: convo, context: context, label: request.model, relayID: relayID)
        try? context.save()
        var sent: [String] = []
        // 工作模式的回复是一份完整的汇报，不拆成几条
        var rich = persona.canWork
        typing[convo.id] = persona.id

        /// 像真人一样一句一句发：每说完一段（空一行），就把这段作为一条消息发出去，接着「输入中」
        /// 闲聊时：一段写完才整条冒出来（之前只显示「正在输入」）；带格式、很长的认真回答或工作模式，边写边显示、整段一条
        buffer.hold = !rich
        var lastCommit = ContinuousClock.now

        /// 像真人打字：下一条按长度留出 0.8～3 秒的「打字时间」，期间显示跳动的小点
        func pace(for text: String) async {
            guard !sent.isEmpty else { return }
            let wait = Duration.seconds(min(3.0, max(0.8, 0.5 + Double(text.count) * 0.06)))
            let remain = wait - (ContinuousClock.now - lastCommit)
            if remain > .zero { try? await Task.sleep(for: remain) }
        }

        func becomeRich() {
            rich = true
            buffer.hold = false
        }

        func commitParagraphs() async {
            while !rich, let range = buffer.text.range(of: "\n\n") {
                let head = String(buffer.text[..<range.lowerBound]).trimmed
                let rest = String(buffer.text[range.upperBound...])
                guard !head.isEmpty else { buffer.text = rest; continue }
                // 带格式或特别长的一段：是认真的回答，整段放一条，不拆
                if Self.looksRich(head) || head.count > 140 { becomeRich(); return }
                await pace(for: head)
                let cleaned = applyMarkers(head, to: message, persona: persona, convo: convo, context: context)
                buffers[message.id] = nil
                if cleaned.isEmpty {
                    // 这一段只有一个表情：表情已经单独发出，空气泡不要了
                    context.delete(message)
                } else {
                    message.content = cleaned
                    message.status = .done
                    sent.append(cleaned)
                }
                speaking.insert(convo.id)
                lastCommit = .now
                (message, buffer) = newBubble(persona, in: convo, context: context, label: request.model, relayID: relayID)
                buffer.hold = true
                buffer.text = rest
                try? context.save()
            }
        }

        do {
            guard let relay else { throw RelayError.notConfigured }
            var pendingText = ""
            var pendingReasoning = ""
            var lastFlush = ContinuousClock.now
            for try await event in relay.run(request, id: relayID) {
                switch event {
                case .text(let s): pendingText += s
                case .reasoning(let s): pendingReasoning += s
                case .step(let s):
                    buffer.steps.append(s)
                    message.steps = buffer.steps.joined(separator: "\n")
                case .file(let name, let data):
                    // 工作模式发回手机的文件：单独一条文件消息
                    deliver(file: name, data: data, from: persona, in: convo, context: context)
                }
                if ContinuousClock.now - lastFlush > .milliseconds(50) {
                    buffer.text += pendingText
                    buffer.reasoning += pendingReasoning
                    pendingText = ""
                    pendingReasoning = ""
                    lastFlush = .now
                    // 只有你屏幕上已经看到 TA 在说话，才算「开口了」；还藏着没显示时被你插话，就重新看全部再回
                    if !buffer.text.trimmed.isEmpty && !buffer.hold { speaking.insert(convo.id) }
                    if !rich && Self.looksRich(buffer.text) { becomeRich() }
                    await commitParagraphs()
                }
            }
            buffer.text += pendingText
            buffer.reasoning += pendingReasoning
            // 被你插话打断了：还藏着没显示的半段话直接丢掉
            if Task.isCancelled { throw CancellationError() }
            await commitParagraphs()
            if buffer.text.trimmed.isEmpty && sent.isEmpty && !Task.isCancelled { throw RelayError.server("没有收到回复。") }
            // 最后一条也按打字节奏出现
            if !rich && !buffer.text.trimmed.isEmpty { await pace(for: buffer.text) }
            buffer.hold = false
            message.status = .done
        } catch {
            if Task.isCancelled || error is CancellationError {
                message.status = .done
                if buffer.hold { buffer.text = "" }
            } else {
                message.status = .error
                message.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        buffers[message.id] = nil
        message.content = message.status == .done
            ? applyMarkers(buffer.text.trimmed, to: message, persona: persona, convo: convo, context: context)
            : buffer.text.trimmed
        message.reasoning = buffer.reasoning.trimmed
        message.steps = buffer.steps.joined(separator: "\n")
        if message.status == .done && message.content.isEmpty && message.steps.isEmpty {
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

    /// TA 能发的表情分类：只用你的图片表情包（不用颜文字）
    static func stickerCategories(context: ModelContext) -> [String] {
        let stickers = (try? context.fetch(FetchDescriptor<Sticker>())) ?? []
        var names: [String] = []
        for s in stickers where !names.contains(s.pack) { names.append(s.pack) }
        return names
    }

    /// 处理 TA 回复里的小标记，返回去掉标记后的文字：
    /// 【引用:…】把你说过的那句话挂在 TA 这条消息下面；【表情:分类】从你的表情库里挑一个发出来
    private func applyMarkers(_ text: String, to message: Message, persona: Persona, convo: Conversation,
                              context: ModelContext) -> String {
        var body = text
        // 中英文括号都认：【】 和 []
        if let regex = try? Regex("[【\\[]引用[:：]\\s*(.+?)[】\\]]"), let match = body.firstMatch(of: regex),
           let key = match.output[1].substring.map({ String($0).trimmed }) {
            body.removeSubrange(match.range)
            let candidates = convo.visibleMessages().reversed().filter { $0.role == .user && !$0.recalled && !$0.content.isEmpty }
            if let quoted = candidates.first(where: { $0.content.contains(key) || key.contains($0.content.prefix(8)) }) {
                let line = quoted.content.replacingOccurrences(of: "\n", with: " ")
                message.quote = "你：" + (line.count > 60 ? String(line.prefix(60)) + "…" : line)
                message.quoteID = quoted.id
            }
        }
        while let regex = try? Regex("[【\\[]表情[:：]\\s*(.+?)[】\\]]"), let match = body.firstMatch(of: regex) {
            let name = match.output[1].substring.map { String($0).trimmed } ?? ""
            body.removeSubrange(match.range)
            let stickers = ((try? context.fetch(FetchDescriptor<Sticker>())) ?? []).filter { $0.pack == name }
            // 图片表情：单独一条表情消息，跟在这条后面；找不到这个分类就不发
            if let pick = stickers.randomElement() {
                let sticker = Message(role: .assistant, kind: .sticker, content: "", personaID: persona.id)
                sticker.createdAt = .now.addingTimeInterval(0.001)
                sticker.conversation = convo
                context.insert(sticker)
                let a = Attachment(kind: "image", fileName: "sticker.png", data: pick.data, order: 0)
                a.message = sticker
                context.insert(a)
            }
        }
        // TA 偶尔会用文字假装发表情（比如「[表情]」「【捂脸表情】」），这种直接去掉，不留在消息里
        if let regex = try? Regex("[【\\[][^】\\]]{0,8}表情[^】\\]]{0,8}[】\\]]") {
            body = body.replacing(regex, with: "")
        }
        return body.trimmed
    }

    /// 记忆打通：在群里也记得你们私聊的事，私聊时也记得群里聊过的事
    private func sharedMemory(of persona: Persona, besides convo: Conversation, context: ModelContext) -> String {
        let all = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        let others = all.filter { $0.id != convo.id && $0.memberIDs.contains(persona.id) }
        let personas = context.allPersonas()
        let names = Dictionary(personas.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let since = Date.now.addingTimeInterval(-24 * 3600)
        var parts: [String] = []
        for c in others.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(3) {
            let members = c.memberIDs.compactMap { id in personas.first { $0.id == id } }
            let place = c.isGroup ? "在群聊「\(c.displayTitle(members))」里" : "你和\(PromptBuilder.userName)私下聊天时"
            var block: [String] = []
            let memory = c.memory.trimmed
            if !memory.isEmpty {
                block.append("\(place)记得的事：\n" + (memory.count > 500 ? String(memory.prefix(500)) + "…" : memory))
            }
            // 最近一天在那边聊的几句：让刚说过的事（比如「我去群里说一声」）在这边也接得上
            let recent = c.visibleMessages().filter { $0.createdAt >= since && $0.status == .done && !$0.recalled }.suffix(8)
            if !recent.isEmpty {
                let note = c.isGroup
                    ? "\(place)最近在聊："
                    : "\(place)最近说的话（只有你们俩知道；在群里别主动说出来，除非 TA 自己先提）："
                block.append(note + "\n" + PromptBuilder.transcript(Array(recent), names: names))
            }
            if !block.isEmpty { parts.append(block.joined(separator: "\n")) }
        }
        return parts.joined(separator: "\n\n")
    }

    /// 电脑发回来的文件：图片显示成照片，其他显示成文件卡片
    private func deliver(file name: String, data: Data, from persona: Persona, in convo: Conversation, context: ModelContext) {
        let ext = (name as NSString).pathExtension.lowercased()
        let isImage = ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext)
        let m = Message(role: .assistant, kind: isImage ? .images : .file, content: "", personaID: persona.id)
        m.conversation = convo
        context.insert(m)
        let a = Attachment(kind: isImage ? "image" : "file", fileName: name, data: data, order: 0)
        a.message = m
        context.insert(a)
        try? context.save()
    }

    // MARK: - 取回中断的回复

    @ObservationIgnored private var recovering = false

    /// App 被关掉时还没收完的回复：电脑上其实已经写好了，连上后按编号取回，补成完整的几条消息
    func recover(context: ModelContext) async {
        guard !recovering, let relay else { return }
        recovering = true
        defer { recovering = false }
        let all = (try? context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.statusRaw == "streaming" }))) ?? []
        let orphans = all.filter { !$0.relayID.isEmpty && buffers[$0.id] == nil }
        let groups = Dictionary(grouping: orphans, by: \.relayID)
        for (relayID, stuck) in groups {
            guard let convo = stuck.first?.conversation, !busy.contains(convo.id) else { continue }
            // 同一次回复里已经发出去的几条
            let siblings = (convo.messages ?? []).filter { $0.relayID == relayID }.sorted { $0.createdAt < $1.createdAt }
            guard let first = siblings.first else { continue }
            var text = ""
            var steps: [String] = []
            var files: [(String, Data)] = []
            do {
                for try await event in relay.resume(relayID) {
                    switch event {
                    case .text(let s): text += s
                    case .step(let s): steps.append(s)
                    case .file(let name, let data): files.append((name, data))
                    case .reasoning: break
                    }
                }
            } catch {
                for m in stuck {
                    m.status = .error
                    m.errorText = (error as? LocalizedError)?.errorDescription ?? "回复被中断"
                }
                try? context.save()
                continue
            }
            // 按和实时一样的规则重新分成几条：说完一段就是一条，带格式的或工作汇报整段一条
            let persona = first.personaID.flatMap { id in context.allPersonas().first { $0.id == id } }
            let whole = Self.looksRich(text) || persona?.canWork == true
            let parts = whole ? [text.trimmed].filter { !$0.isEmpty }
                : text.components(separatedBy: "\n\n").map(\.trimmed).filter { !$0.isEmpty }
            guard !parts.isEmpty || !files.isEmpty else { continue }
            let start = first.createdAt
            let personaID = first.personaID
            let label = first.modelLabel
            for m in siblings { context.delete(m) }
            for (i, part) in parts.enumerated() {
                let m = Message(role: .assistant, content: part, personaID: personaID)
                m.modelLabel = label
                m.relayID = relayID
                m.steps = i == 0 ? steps.joined(separator: "\n") : ""
                m.createdAt = start.addingTimeInterval(Double(i) * 0.001)
                m.conversation = convo
                context.insert(m)
            }
            if let persona {
                for (name, data) in files { deliver(file: name, data: data, from: persona, in: convo, context: context) }
            }
            convo.updatedAt = .now
            try? context.save()
        }
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

    static func system(for persona: Persona, convo: Conversation?, members: [Persona], stickerCategories: [String] = []) -> String {
        var parts: [String] = []
        let base = persona.systemPrompt.trimmed
        parts.append(base.isEmpty ? "你是「\(persona.name)」。" : base)
        parts.append("""
        你在一个手机聊天 App 里和\(userName)聊天。像发消息一样自然、口语化地回复，不要长篇大论；想分几条说的时候用空行隔开，每段一两句话。只有内容复杂时才用 Markdown。不要用颜文字（比如 (≧▽≦)、^^ 这种）。
        """)
        if let convo, convo.isGroup {
            let others = members.filter { $0.id != persona.id }.map(\.name)
            let roster = (["\(userName)（用户）"] + others).joined(separator: "、")
            parts.append("""
            你正在群聊「\(convo.displayTitle(members))」里，你的名字是「\(persona.name)」。群成员：\(roster)。
            只以「\(persona.name)」的身份说话，不要替别人发言，不要在开头写自己的名字。
            """)
        }
        if !stickerCategories.isEmpty {
            parts.append("""
            想发表情包时，单独一段只写【表情:分类名】，可以用的分类只有这些：\(stickerCategories.joined(separator: "、"))。偶尔用一下就好，不要每次都发；没有合适的分类就不发，也不要用文字描述或假装发表情。
            想针对\(userName)之前说的某句话回应时，可以在那一段开头写【引用:那句话里的几个字】，像聊天软件里的引用回复；同样偶尔用。
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
        case .file: body = "[发了文件：\(m.sortedAttachments.map(\.fileName).joined(separator: "、"))]" + (m.content.isEmpty ? "" : " \(m.content)")
        case .note: body = "【写下的想法】\(m.content)"
        case .sticker: body = "[发了一个表情]"
        }
        if !m.quote.isEmpty { body = "（引用「\(m.quote)」）" + body }
        if m.recalled { body = "（撤回了一条消息）" }
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
                        discussing: Bool = false, diaryNotes: String = "", sharedMemory: String = "",
                        stickerCategories: [String] = []) -> RelayRequest {
        let names = Dictionary(members.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let shared = sharedMemory.isEmpty ? "" : "\(sharedMemory)\n\n"
        // 感知聊天间隔：隔了很久你再来找 TA，TA 会自然地说「好久没聊了」
        var gapLine = ""
        let visible = history.filter { $0.status != .error && !$0.recalled }
        if let latest = visible.last, latest.role == .user,
           let previous = visible.dropLast().last(where: { $0.createdAt < latest.createdAt.addingTimeInterval(-1) }) {
            let gap = latest.createdAt.timeIntervalSince(previous.createdAt)
            if gap >= 3 * 86400 {
                gapLine = "（距离你们上一次聊天已经过去了\(Fmt.duration(gap))，可以自然地表现出好久没聊了。）"
            } else if gap >= 12 * 3600 {
                gapLine = "（上一次聊天是\(Fmt.duration(gap))前，心里知道就好，不用特意提，自然地接着聊。）"
            }
        }
        let ask = discussing
            ? "大家正在讨论，请以「\(persona.name)」的身份接着说：可以回应其他人的观点、补充或提出不同看法，不要重复别人说过的。"
            : "请以「\(persona.name)」的身份回复。"
        // 你最近写的日记：TA 会记在心上，合适的时候自然地关心，但不要生硬地复述
        let diary = diaryNotes.isEmpty ? "" : "\(userName)最近几天写的日记（记在心上，合适时自然地关心，不要生硬复述）：\n\(diaryNotes)\n\n"
        let prompt = """
        \(shared)\(diary)下面是你们最近的聊天记录：

        \(transcript(recent(history, convo: convo), names: names))

        现在是 \(Fmt.time24.string(from: .now))。\(gapLine)\(ask)直接输出要说的话，不要加名字或时间。
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
                            system: system(for: persona, convo: convo, members: members,
                                           stickerCategories: persona.canWork ? [] : stickerCategories),
                            prompt: prompt, attachments: attachments, work: persona.canWork)
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
