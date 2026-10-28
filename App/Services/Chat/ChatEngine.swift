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
    /// 正在取回中断的回复（见 ChatEngine+Recover），避免同时取两遍
    @ObservationIgnored var recovering = false
    @ObservationIgnored private(set) weak var relay: RelayClient?
    @ObservationIgnored private weak var banners: BannerCenter?
    @ObservationIgnored private weak var router: Router?

    func attach(relay: RelayClient, banners: BannerCenter, router: Router) {
        self.relay = relay
        self.banners = banners
        self.router = router
    }

    func isBusy(_ convo: Conversation) -> Bool { busy.contains(convo.id) }

    // MARK: - 发送

    /// 你说了一次话。照片和文件一起发时分成两条（照片带着文字一条、文件一条），但只算一次，按这句话决定谁来回
    func send(_ text: String, kind: MessageKind = .text, attachments: [OutgoingAttachment] = [], quote: String = "", quoteID: UUID? = nil,
              in convo: Conversation, members: [Persona], context: ModelContext) {
        let images = attachments.filter { $0.kind == "image" }
        let files = attachments.filter { $0.kind != "image" }
        let parts: [(kind: MessageKind, text: String, items: [OutgoingAttachment])] =
            kind != .sticker && !images.isEmpty && !files.isEmpty
                ? [(.images, text, images), (.file, "", files)]
                : [(kind, text, attachments)]
        let now = Date.now
        for (index, part) in parts.enumerated() {
            let message = Message(role: .user, kind: part.kind, content: part.text)
            message.createdAt = now.addingTimeInterval(Double(index) * 0.00001)
            if index == 0 {
                message.quote = quote
                message.quoteID = quoteID
            }
            message.conversation = convo
            context.insert(message)
            for (order, item) in part.items.enumerated() {
                let a = Attachment(kind: item.kind, fileName: item.name, data: item.data, order: order)
                a.message = message
                context.insert(a)
            }
        }
        convo.updatedAt = .now
        convo.lastReadAt = .now
        Companion.cancelPlannedMessages(in: convo, context: context)
        try? context.save()
        let responders = Self.responders(for: text, convo: convo, members: members)
        if busy.contains(convo.id) {
            // 像真人聊天一样可以连着发。连着 @ 了不同的人，这些人都要回
            pending[convo.id] = Self.merge(pending[convo.id] ?? [], responders)
            // TA 还没开口就重新看一遍再回；已经在说了，就把正在打的这句说完，再看了你的新消息一起回。
            //（「正在输入」的小点一直排在最底下，你新发的消息插在它上面）
            if !speaking.contains(convo.id) { tasks[convo.id]?.cancel() }
            return
        }
        run(responders, in: convo, members: members, context: context, react: true)
    }

    /// 你撤回或编辑了消息：TA 还没开口就重新看一遍再回；已经在说了就算了。
    /// 你在 TA 上次说话后发的都撤回了，TA 就不用回了
    func reconsider(_ convo: Conversation, members: [Persona], context: ModelContext) {
        guard busy.contains(convo.id), !speaking.contains(convo.id) else { return }
        let said = convo.visibleMessages().filter { $0.status != .streaming }
        let unanswered = said.reversed().prefix { $0.role == .user }.filter { !$0.recalled }
        guard !unanswered.isEmpty else { return stop(convo) }
        pending[convo.id] = Self.responders(for: unanswered.map(\.content).joined(separator: "\n"), convo: convo, members: members)
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

    /// 合并两批要回复的人，去掉重复，保持先后顺序
    static func merge(_ a: [Persona], _ b: [Persona]) -> [Persona] {
        a + b.filter { p in !a.contains { $0.id == p.id } }
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
                try? await Task.sleep(for: .seconds(Double.random(in: 0.9...2.2)))
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
        // 排在已经出现的消息后面（比如上一段刚带出的表情）
        if let latest = convo.lastVisible()?.createdAt { message.createdAt = max(.now, latest.addingTimeInterval(0.00001)) }
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
                                            sharedMemory: PromptBuilder.sharedMemory(of: persona, besides: convo, context: context),
                                            stickerCategories: PromptBuilder.stickerCategories(context: context),
                                            appointments: Appointments.summary(persona: persona, convo: convo))
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

        /// 你在 TA 说话途中又发了消息：TA 把正在打的这句发完就停下，剩下没说的不再接着念，回头看了你的新消息再回
        var interrupted = false

        func commitParagraphs() async {
            while !rich, !interrupted, let range = buffer.text.range(of: "\n\n") {
                let head = String(buffer.text[..<range.lowerBound]).trimmed
                let rest = String(buffer.text[range.upperBound...])
                guard !head.isEmpty else { buffer.text = rest; continue }
                // 带格式或特别长的一段：是认真的回答，整段放一条，不拆
                if ReplyText.looksRich(head) || head.count > 140 { becomeRich(); return }
                await pace(for: head)
                // 藏着打字的这条，以真正冒出来的时刻为准
                message.createdAt = max(.now, message.createdAt)
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
                if pending[convo.id] != nil {
                    interrupted = true
                    try? context.save()
                    return
                }
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
                    // 已经开始操作电脑了：你再插话也不打断重来，免得同样的操作做两遍
                    speaking.insert(convo.id)
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
                    if !rich && ReplyText.looksRich(buffer.text) { becomeRich() }
                    await commitParagraphs()
                    if interrupted { break }
                }
            }
            if interrupted {
                // 刚发完的那句就是这一轮的最后一句：后面的不要了
                if let last = sent.last { notify(convo: convo, persona: persona, text: last) }
                convo.updatedAt = .now
                if router?.openConversation == convo.id { convo.lastReadAt = .now }
                try? context.save()
                return
            }
            buffer.text += pendingText
            buffer.reasoning += pendingReasoning
            // 被你插话打断了：还藏着没显示的半段话直接丢掉
            if Task.isCancelled { throw CancellationError() }
            await commitParagraphs()
            if buffer.text.trimmed.isEmpty && sent.isEmpty && !Task.isCancelled { throw RelayError.server("没有收到回复。") }
            // 最后一条也按打字节奏出现
            if !rich && !buffer.text.trimmed.isEmpty { await pace(for: buffer.text) }
            if buffer.hold { message.createdAt = max(.now, message.createdAt) }
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

    /// 处理 TA 回复里的小标记，返回去掉标记后的文字：
    /// 【引用:…】把你说过的那句话挂在 TA 这条消息下面；【表情:分类】从你的表情库里挑一个，单独一条跟在后面；
    /// 【约定:时间|事情】【取消约定:事情】记下或撤掉约定（到点 TA 真的来找你）
    func applyMarkers(_ text: String, to message: Message, persona: Persona, convo: Conversation,
                      context: ModelContext) -> String {
        let markers = ReplyText.markers(in: text)
        if let key = markers.quoteKey, let quoted = ReplyText.quoted(key, in: convo.visibleMessages()) {
            message.quote = ReplyText.quoteLine(for: quoted)
            message.quoteID = quoted.id
        }
        for what in markers.cancels { Appointments.cancel(what, persona: persona, convo: convo, context: context) }
        for promise in markers.promises {
            Appointments.promise(promise, persona: persona, convo: convo, context: context, relay: relay)
        }
        let stickers = markers.stickerPacks.isEmpty ? [] : (try? context.fetch(FetchDescriptor<Sticker>())) ?? []
        for pack in markers.stickerPacks {
            // 找不到这个分类就不发
            guard let pick = stickers.filter({ $0.pack == pack }).randomElement() else { continue }
            let sticker = Message(role: .assistant, kind: .sticker, content: "", personaID: persona.id)
            sticker.createdAt = max(.now, message.createdAt).addingTimeInterval(0.00001)
            sticker.conversation = convo
            context.insert(sticker)
            let a = Attachment(kind: "image", fileName: "sticker.png", data: pick.data, order: 0)
            a.message = sticker
            context.insert(a)
        }
        return markers.body
    }

    /// 电脑发回来的文件：图片显示成照片，其他显示成文件卡片
    func deliver(file name: String, data: Data, from persona: Persona, in convo: Conversation, context: ModelContext) {
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
}
