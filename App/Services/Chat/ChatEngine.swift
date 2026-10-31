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
    /// 工作模式里正等你点「允许 / 不允许」的那一步
    var approval: PendingApproval?
    /// 打字犹豫：「正在输入」淡出一会儿再出现（像真人打了又删）
    var paused = false
}

struct PendingApproval: Equatable {
    let req: String
    let text: String
}

struct OutgoingAttachment {
    var kind: AttachmentKind
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
    /// 正在翻译的消息（下面显示「翻译中…」，见 ChatEngine+Translate）
    var translating: Set<UUID> = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// 回复途中用户又发了消息：等这一轮说完（或直接打断）后，再按新的上下文回复
    @ObservationIgnored private var pending: [UUID: [Persona]] = [:]
    /// 这一轮回复是不是已经开始出字了
    @ObservationIgnored private var speaking: Set<UUID> = []
    /// TA 正在打字时被你插话：那个「正在输入」的气泡留着，TA 看完你的新消息接着在里面打（对话 ID -> 那条消息）
    @ObservationIgnored private var carried: [UUID: Message] = [:]
    /// 重新生成：要被换掉的那条旧回复（对话 ID -> 消息）。新的说出第一句才拿掉它；没换成就一直留着
    @ObservationIgnored private var replacing: [UUID: Message] = [:]
    /// 要在聊天页轻轻提示一句的事（对话 ID -> 那句话）：聊天页看到后提示，然后清掉
    var notices: [UUID: String] = [:]
    /// 语音服务出了要你处理的问题（额度用完、密钥不对）：每次打开 App 只提醒一次，不每句都提醒
    @ObservationIgnored private var voiceWarned = false
    /// 重新生成没成功的对话：聊天页看到后提示一句「原来的回复还在」，然后清掉
    var redoFailed: Set<UUID> = []
    /// 切到后台时向系统多要一点时间，让正在进行的回复写完
    @ObservationIgnored private var background: [UUID: UIBackgroundTaskIdentifier] = [:]
    /// 正在取回中断的回复（见 ChatEngine+Recover），避免同时取两遍
    @ObservationIgnored var recovering = false
    /// TA 在忙、晚点才回（见 HumanTouch.lateness）：正在写的那次、为什么忙
    @ObservationIgnored private var latePlans: [UUID: HumanTouch.Late] = [:]
    @ObservationIgnored private var lateTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lateReasons: [UUID: String] = [:]
    /// 回拍、记忆整理、补一句这些小任务（对话 ID → 任务），见 keep
    @ObservationIgnored private var sideTasks: [UUID: [UUID: Task<Void, Never>]] = [:]
    /// 电脑没连上时排队的提示：每次打开 App 只说一次
    @ObservationIgnored private var queuedNoticeShown = false
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
        let images = attachments.filter { $0.kind == .image }
        let files = attachments.filter { $0.kind != .image }
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
            // 你发出的消息：上面的消息平滑地往上让开。图片、文件和消息一起放进去，
            // 不会先冒出一个空的再变高
            withAnimation(Motion.bubble) {
                convo.add(message, context: context)
                for (order, item) in part.items.enumerated() {
                    let a = Attachment(kind: item.kind, fileName: item.name, data: item.data, order: order)
                    a.message = message
                    context.insert(a)
                }
            }
        }
        convo.updatedAt = .now
        convo.lastReadAt = .now
        // TA 正在忙、晚回的那几条已经排好了：你又说了话，按同一个时间重新写（把你新说的也回了），TA 不会因为你多发几条就突然有空
        let waiting = convo.plannedMessages().filter { PlannedMessages.marker(of: $0)?.isLate == true }
        let carriedLate = latePlans[convo.id] ?? waiting.min(by: { $0.createdAt < $1.createdAt }).map {
            HumanTouch.Late(deliver: $0.createdAt, reason: lateReasons[convo.id] ?? "在忙", read: PlannedMessages.marker(of: $0) == .lateRead)
        }
        // 正在写的那次晚回停下、清干净（下面要么按同一个时间重写，要么照常马上回），后台时间也还回去
        if lateTasks[convo.id] != nil || latePlans[convo.id] != nil {
            lateTasks[convo.id]?.cancel()
            lateTasks[convo.id] = nil
            latePlans[convo.id] = nil
            releaseBackground(convo.id)
        }
        PlannedMessages.cancelForYourTurn(in: convo, context: context)
        context.persist()
        var responders = Self.responders(for: text, convo: convo, members: members)
        // 群里没 @ 谁：不是每个人都回，有人潜水
        if convo.isGroup, members.count > 1, responders.count == members.count, !text.contains("@所有人") {
            responders = Self.lurking(members)
        }
        // 电脑没连上：消息照常发出、先不显示已读，连上以后 TA 再回（见 answerQueued）
        if !busy.contains(convo.id), !(relay?.isConnected ?? false), !DemoMode.isOn {
            if !queuedNoticeShown {
                queuedNoticeShown = true
                notices[convo.id] = String(localized: "电脑还没连上，连上后 TA 就会回你")
            }
            return
        }
        if !busy.contains(convo.id), let persona = responders.first, let relay, relay.isConnected,
           let late = carriedLate.flatMap({ $0.deliver > .now.addingTimeInterval(20) ? $0 : nil })
                ?? HumanTouch.lateness(for: persona, convo: convo) {
            planLate(late, persona: persona, convo: convo, members: members, context: context, relay: relay)
            return
        }
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

    /// TA 在忙：看到了就先显示已读、过一阵再回；没看到就一直未读，到回的时候才算看过。
    /// 回复先写好、排在那个时间出现（App 关着也会到点弹通知）；没写成就照常马上回
    private func planLate(_ late: HumanTouch.Late, persona: Persona, convo: Conversation, members: [Persona],
                          context: ModelContext, relay: RelayClient) {
        let convoID = convo.id
        latePlans[convoID] = late
        lateReasons[convoID] = late.reason
        holdBackground(convoID)
        lateTasks[convoID] = Task { [weak self] in
            if late.read {
                try? await Task.sleep(for: .seconds(Double.random(in: 1...2.5)))
                if !Task.isCancelled { withAnimation(Motion.bubble) { self?.markRead(convo, context: context) } }
            } else {
                // 到 TA 回的前一小会儿才算看过（已读只在那之后显示）
                let seen = late.deliver.addingTimeInterval(-Double.random(in: 5...20))
                for m in convo.messages ?? [] where m.role == .user && m.readAt == nil { m.readAt = seen }
                context.persist()
            }
            let written = await HumanTouch.writeLate(late, persona: persona, convo: convo, members: members, context: context, relay: relay)
            guard let self, !Task.isCancelled else { return }
            self.latePlans[convoID] = nil
            self.lateTasks[convoID] = nil
            self.releaseBackground(convoID)
            if !written {
                // 没写成（断线、出错）：别让你一直等，照常马上回
                for m in convo.messages ?? [] where m.role == .user && (m.readAt ?? .distantPast) > .now { m.readAt = nil }
                self.run([persona], in: convo, members: members, context: context, react: true)
            }
        }
    }

    /// 连上电脑以后：你在断开期间发的、TA 还没看过的消息（最近一天内），按正常规则回（在忙就晚点回）
    func answerQueued(context: ModelContext) {
        guard let relay, relay.isConnected, !DemoMode.isOn else { return }
        let convos = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        let personas = context.allPersonas()
        let since = Date.now.addingTimeInterval(-86400)
        for convo in convos where !busy.contains(convo.id) && latePlans[convo.id] == nil && lateTasks[convo.id] == nil {
            let said = convo.visibleMessages().filter { $0.status != .streaming }
            guard let last = said.last, last.role == .user, !last.recalled, last.readAt == nil, last.createdAt > since else { continue }
            // 晚回已经排好了：到点照常来
            guard !convo.plannedMessages().contains(where: { PlannedMessages.marker(of: $0)?.isLate == true }) else { continue }
            let members = convo.memberIDs.compactMap { id in personas.first { $0.id == id } }
            guard !members.isEmpty else { continue }
            let unanswered = said.reversed().prefix { $0.role == .user }.filter { !$0.recalled }
            let text = unanswered.map(\.content).joined(separator: "\n")
            var responders = Self.responders(for: text, convo: convo, members: members)
            if convo.isGroup, members.count > 1, responders.count == members.count, !text.contains("@所有人") {
                responders = Self.lurking(members)
            }
            guard let persona = responders.first else { continue }
            if let late = HumanTouch.lateness(for: persona, convo: convo) {
                planLate(late, persona: persona, convo: convo, members: members, context: context, relay: relay)
            } else {
                run(responders, in: convo, members: members, context: context, react: true)
            }
        }
    }

    /// 拍一拍：你双击了 TA 的头像。TA 有时回拍你一下，有时看到「你拍了拍 TA」回一句
    func nudge(_ persona: Persona, in convo: Conversation, members: [Persona], context: ModelContext) {
        let m = Message(role: .user, kind: .nudge, content: persona.name)
        withAnimation(Motion.bubble) { convo.add(m, context: context) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        convo.updatedAt = .now
        convo.lastReadAt = .now
        // TA 正在忙、晚点回的那几条已经排好了：拍一拍不会让 TA 突然有空，只留下这一行，TA 到点再回
        let lateWaiting = latePlans[convo.id] != nil
            || convo.plannedMessages().contains { PlannedMessages.marker(of: $0)?.isLate == true }
        if lateWaiting {
            context.persist()
            return
        }
        PlannedMessages.cancelForYourTurn(in: convo, context: context)
        context.persist()
        // 电脑没连上：先留着这一下，连上后 TA 再回
        guard !busy.contains(convo.id), relay?.isConnected ?? false else { return }
        if Double.random(in: 0..<1) < 0.35 {
            keep(convo.id) { [weak self] in
                // 被停下（清空聊天、删角色）就不回拍了
                try? await Task.sleep(for: .seconds(Double.random(in: 1.2...2.6)))
                guard !Task.isCancelled else { return }
                self?.patBack(persona, in: convo, context: context, after: .now)
            }
        } else {
            run([persona], in: convo, members: members, context: context, react: true)
        }
    }

    /// TA 拍了拍你
    private func patBack(_ persona: Persona, in convo: Conversation, context: ModelContext, after: Date) {
        let m = Message(role: .assistant, kind: .nudge, content: "", personaID: persona.id)
        m.createdAt = max(.now, after).addingTimeInterval(0.000008)
        withAnimation(Motion.bubble) { convo.add(m, context: context) }
        context.persist()
    }

    /// 群里没 @ 谁：不是每个人都回，有人潜水（至少一个人回）
    static func lurking(_ members: [Persona]) -> [Persona] {
        let order = members.shuffled()
        guard let first = order.first else { return [] }
        return [first] + order.dropFirst().filter { _ in Double.random(in: 0..<1) < 0.6 }
    }

    /// TA 开始看你的消息了：你发的消息显示已读双勾
    private func markRead(_ convo: Conversation, context: ModelContext) {
        let now = Date.now
        var changed = false
        // 晚回「没看到」时已读排在以后；改成现在就回了，已读也提前到现在
        for m in convo.messages ?? [] where m.role == .user && (m.readAt ?? .distantFuture) > now && m.createdAt <= now {
            m.readAt = now
            changed = true
        }
        if changed { context.persist() }
    }

    func regenerate(_ message: Message, in convo: Conversation, members: [Persona], context: ModelContext) {
        guard !isBusy(convo), message.role == .assistant else { return }
        // 角色已经删掉时不动
        guard let persona = members.first(where: { $0.id == message.personaID }) ?? (convo.isGroup ? nil : members.first)
        else { return }
        // 出错的那条直接换掉；好好的回复先留着，等新的说出第一句再拿掉（新的失败了，原来的还在）
        if message.status == .error {
            withAnimation(Motion.bubble) { context.delete(message) }
            context.persist()
        } else {
            replacing[convo.id] = message
        }
        run([persona], in: convo, members: members, context: context)
    }

    /// 你在工作模式的确认卡片上点了「允许 / 不允许」
    func answer(_ message: Message, ok: Bool) {
        guard let buffer = buffers[message.id], let pending = buffer.approval else { return }
        relay?.answer(pending.req, ok: ok)
        withAnimation(Motion.bubble) { buffer.approval = nil }
    }

    /// 你点了「停止」：不再等你的新消息，正在写的这段停下（已经说出的留着）
    func stop(_ convo: Conversation) {
        pending[convo.id] = nil
        tasks[convo.id]?.cancel()
    }

    /// 清空聊天、删除、重置之前：这个对话里正在做和排着要做的一切都停下——回复、晚回、回拍、记忆整理、补一句。
    /// 等正在写的回复真正收好尾才返回，之后再删数据，就不会有人往删掉的聊天里写（CONC-9）
    func halt(_ convoID: UUID) async {
        pending[convoID] = nil
        let reply = tasks[convoID]
        reply?.cancel()
        lateTasks.removeValue(forKey: convoID)?.cancel()
        latePlans[convoID] = nil
        lateReasons[convoID] = nil
        let side = sideTasks.removeValue(forKey: convoID).map { Array($0.values) } ?? []
        side.forEach { $0.cancel() }
        await reply?.value
        for task in side { await task.value }
        carried[convoID] = nil
        replacing[convoID] = nil
        notices[convoID] = nil
        redoFailed.remove(convoID)
        releaseBackground(convoID)
    }

    /// 跟着某个对话、活得比一次调用久的小任务（回拍、记忆整理、补一句）：存起来，halt 时一起停（CONC-3）
    private func keep(_ convoID: UUID, _ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        sideTasks[convoID, default: [:]][id] = Task { [weak self] in
            await work()
            self?.sideTasks[convoID]?[id] = nil
        }
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
        guard !busy.contains(convoID) else { return }
        guard !responders.isEmpty else { return dropCarried(convoID, context: context) }
        busy.insert(convoID)
        holdBackground(convoID)
        // 群聊可以设置自动讨论几轮：第一轮按 @ 回复，之后大家接着彼此的话说
        // 「偶尔」：大多数时候各回一次，有时会接着聊上两三轮，像真的群聊一样不固定
        let occasional = Double.random(in: 0..<1)
        let rounds = switch convo.isGroup ? convo.discuss : .rounds(1) {
        case .occasional: occasional < 0.6 ? 1 : occasional < 0.88 ? 2 : 3
        case .rounds(let n): n
        }
        tasks[convoID] = Task { [weak self] in
            // 像真人一样，看到消息后过一小会儿才开始回（每次不一样）；这期间你又发了，就一起看、一起回
            if react {
                // 先「已读」，过一会儿才开始打字
                try? await Task.sleep(for: .seconds(Double.random(in: 0.9...2.2)))
                if !Task.isCancelled { withAnimation(Motion.bubble) { self?.markRead(convo, context: context) } }
                try? await Task.sleep(for: .seconds(Double.random(in: 0.4...1.8)))
            } else {
                self?.markRead(convo, context: context)
            }
            var spoke = false
            // 群里有人在话里 @ 了别人：被 @ 的人接着回（一轮最多插两次，免得两个人一直互相 @ 停不下来）
            var extra = 0
            rounds: for round in 0..<rounds {
                var queue = round == 0 ? responders : members
                var index = 0
                while index < queue.count {
                    let persona = queue[index]
                    index += 1
                    // 群聊换人回：上一个人这句冒出来以后停一小会儿，下一个人的「正在输入」才出现。
                    // 以前紧跟着就冒出来，和上一句变成文字的动画撞在同一瞬间，名字还会压到上一条上（真机录屏）
                    if spoke { try? await Task.sleep(for: .milliseconds(450)) }
                    guard let self, !Task.isCancelled, self.pending[convoID] == nil else { break rounds }
                    await self.reply(as: persona, in: convo, members: members, context: context, discussing: round > 0)
                    spoke = true
                    guard convo.isGroup, extra < 2,
                          let said = convo.visibleMessages().last(where: { $0.role == .assistant && $0.personaID == persona.id })?.content
                    else { continue }
                    for other in members where other.id != persona.id && said.contains("@\(other.name)")
                        && !queue[index...].contains(where: { $0.id == other.id }) && extra < 2 {
                        queue.insert(other, at: index)
                        extra += 1
                    }
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
            self.dropCarried(convoID, context: context)
            self.releaseBackground(convoID)
            // 被停下了（清空聊天、删除）：不再整理记忆、不补一句
            guard !Task.isCancelled else { return }
            // 聊得够多了，就在后台把更早的部分整理进长期记忆
            if let relay = self.relay {
                self.keep(convoID) { await Memory.updateIfNeeded(convo, members: members, context: context, relay: relay) }
                // 偶尔过几分钟又想起来补一句（单聊）
                if !convo.isGroup, let persona = responders.first {
                    self.keep(convoID) { await HumanTouch.maybeAfterthought(persona: persona, convo: convo, context: context, relay: relay) }
                }
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

    /// 留着的「正在输入」最后没用上（比如换了别人回、或者不用回了）：轻轻撤掉
    private func dropCarried(_ convoID: UUID, context: ModelContext) {
        guard let kept = carried.removeValue(forKey: convoID) else { return }
        withAnimation(Motion.bubble) {
            buffers[kept.id] = nil
            context.delete(kept)
        }
        context.persist()
    }

    /// 重新生成的新回复已经出现：把旧的那条拿掉（放在调用处的动画里一起完成）
    private func retireReplaced(_ convoID: UUID, context: ModelContext) {
        // 这期间你自己把旧的删掉了：不用再删
        guard let old = replacing.removeValue(forKey: convoID), old.modelContext != nil, !old.isDeleted else { return }
        context.delete(old)
    }

    /// 这一轮的第一个气泡：被插话时留下的那个「正在输入」接着用，否则新开一个
    private func firstBubble(_ persona: Persona, in convo: Conversation, context: ModelContext, label: String,
                             relayID: String) -> (Message, StreamBuffer) {
        if let kept = carried[convo.id], kept.personaID == persona.id, let buffer = buffers[kept.id] {
            carried[convo.id] = nil
            kept.modelLabel = label
            kept.relayID = relayID
            return (kept, buffer)
        }
        dropCarried(convo.id, context: context)
        return newBubble(persona, in: convo, context: context, label: label, relayID: relayID)
    }

    private func newBubble(_ persona: Persona, in convo: Conversation, context: ModelContext, label: String,
                           relayID: String) -> (Message, StreamBuffer) {
        let message = Message(role: .assistant, content: "", personaID: persona.id)
        // 排在已经出现的消息后面（比如上一段刚带出的表情）
        if let latest = convo.lastVisible()?.createdAt { message.createdAt = max(.now, latest.addingTimeInterval(0.00001)) }
        message.status = .streaming
        message.modelLabel = label
        message.relayID = relayID
        let buffer = StreamBuffer()
        buffer.hold = true
        buffers[message.id] = buffer
        // 「正在输入」的气泡出现时，上面的消息平滑地往上让开，不会突然冒出来
        withAnimation(Motion.bubble) {
            convo.add(message, context: context)
        }
        return (message, buffer)
    }

    /// 演示（云端录屏检查动画用）：走和真回复一样的路径，先冒出「正在输入」的小点，过一会儿在原地变成文字
    func demoReply(_ text: String, as persona: Persona, in convo: Conversation, context: ModelContext) async {
        let (message, _) = newBubble(persona, in: convo, context: context, label: "", relayID: "")
        try? await Task.sleep(for: .seconds(1.6))
        message.createdAt = max(.now, message.createdAt)
        withAnimation(Motion.bubble) {
            buffers[message.id] = nil
            message.content = text
            message.status = .done
        }
    }

    private func reply(as persona: Persona, in convo: Conversation, members: [Persona], context: ModelContext,
                       discussing: Bool = false) async {
        // 正在打字、还没出字的那条不算聊天记录；正要被重新生成换掉的那条也不算（TA 不该看到自己上一版的回答）
        let old = replacing[convo.id]?.id
        let history = convo.visibleMessages().filter { $0.status != .streaming && $0.id != old }
        let request = PromptBuilder.request(for: persona, convo: convo, members: members, history: history, discussing: discussing,
                                            diaryNotes: Companion.myDiaryNotes(context: context),
                                            sharedMemory: PromptBuilder.sharedMemory(of: persona, besides: convo, context: context),
                                            stickerCategories: PromptBuilder.stickerCategories(context: context),
                                            appointments: Appointments.summary(persona: persona, convo: convo))
        let relayID = UUID().uuidString
        var (message, buffer) = firstBubble(persona, in: convo, context: context, label: request.model, relayID: relayID)
        context.persist()
        var sent: [String] = []
        // 工作模式的回复是一份完整的汇报，不拆成几条
        var rich = persona.canWork
        typing[convo.id] = persona.id

        /// 像真人一样一句一句发：每说完一段（空一行），就把这段作为一条消息发出去，接着「输入中」
        /// 闲聊时：一段写完才整条冒出来（之前只显示「正在输入」）；带格式、很长的认真回答或工作模式，边写边显示、整段一条
        buffer.hold = !rich
        var lastCommit = ContinuousClock.now

        /// 打字犹豫：开口前偶尔「正在输入」淡掉一会儿再出现，像打了几个字又删掉重想（开了「真人节奏」才会，每轮最多一次）
        var hesitated = false
        func hesitate() async {
            guard !hesitated, !rich, HumanTouch.pace(persona), !DemoMode.isOn else { return }
            hesitated = true
            guard Double.random(in: 0..<1) < 0.18 else { return }
            withAnimation(Motion.fade) { buffer.paused = true }
            try? await Task.sleep(for: .seconds(Double.random(in: 1.2...2.4)))
            withAnimation(Motion.fade) { buffer.paused = false }
            try? await Task.sleep(for: .seconds(Double.random(in: 0.7...1.4)))
        }

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

        /// 这一段 TA 想用语音说（开头写了【语音】）：先用 TA 的声音念好，念的时候还是「正在输入」；
        /// 没设声音、念不出来（比如额度用完）就照常发文字
        let voiceOn = Voice.enabled(for: persona)
        func record(_ text: String) async -> Data? {
            guard voiceOn else { return nil }
            let marks = ReplyText.markers(in: text)
            guard marks.voice, !marks.body.isEmpty else { return nil }
            do {
                return try await Voice.speak(marks.spoken, for: persona)
            } catch let failure as Voice.Failure {
                // 额度用完、密钥不对：照常发文字，但告诉你一声（以前语音就这么悄悄不发了）
                switch failure {
                case .quota, .badKey, .noKey:
                    if !voiceWarned {
                        voiceWarned = true
                        notices[convo.id] = String(localized: "语音没发出去：\(failure.localizedDescription)")
                    }
                case .other: break
                }
                return nil
            } catch {
                return nil
            }
        }

        func attach(_ audio: Data, to m: Message) {
            m.kindRaw = MessageKind.voice.rawValue
            let a = Attachment(kind: .audio, fileName: "voice.mp3", data: audio, order: 0)
            a.message = m
            context.insert(a)
            // 开了「自动翻译语音」：语音一发出就在下面翻好
            if persona.autoTranslate {
                Task { await self.translate(m, context: context) }
            }
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
                if sent.isEmpty { await hesitate() }
                await pace(for: head)
                let audio = await record(head)
                // 藏着打字的这条，以真正冒出来的时刻为准
                message.createdAt = max(.now, message.createdAt)
                let cleaned = applyMarkers(head, to: message, persona: persona, convo: convo, context: context)
                // 这一段只写了心声、没说话：心声留给下一条
                let leftThought = cleaned.isEmpty ? Thoughts.shared.text(message.id) : nil
                // 小点变成文字、气泡撑开、「已读」淡出：放在同一个平滑动画里一起完成
                withAnimation(Motion.bubble) {
                    // 重新生成：新的第一句出来了，旧的那条这时才退场
                    retireReplaced(convo.id, context: context)
                    buffers[message.id] = nil
                    if cleaned.isEmpty {
                        // 这一段只有一个表情：表情已经单独发出，空气泡不要了
                        context.delete(message)
                    } else {
                        message.content = cleaned
                        message.status = .done
                        if let audio { attach(audio, to: message) }
                    }
                }
                if !cleaned.isEmpty { sent.append(audio == nil ? cleaned : "[语音]") }
                speaking.insert(convo.id)
                lastCommit = .now
                // 像 iMessage：这一句冒出来以后停一小会儿，下一条的「正在输入」才出现，
                // 不和这句变成文字的动画挤在同一瞬间（停顿算在下一句的打字时间里，总节奏不变）
                if pending[convo.id] == nil { try? await Task.sleep(for: .milliseconds(450)) }
                if pending[convo.id] != nil {
                    interrupted = true
                    context.persist()
                    return
                }
                (message, buffer) = newBubble(persona, in: convo, context: context, label: request.model, relayID: relayID)
                buffer.hold = true
                if let leftThought { Cleanup.saveThought(leftThought, for: message.id, context: context) }
                buffer.text = rest
                context.persist()
            }
        }

        /// 最后一段如果是语音：念好的音频
        var lastAudio: Data?
        do {
            guard let relay else { throw RelayError.notConfigured }
            var pendingText = ""
            var pendingReasoning = ""
            var lastFlush = ContinuousClock.now
            for try await event in relay.run(request, id: relayID) {
                switch event {
                case .text(let s): pendingText += s
                case .reasoning(let s): pendingReasoning += s
                case .approval(let req, let text):
                    // 断线重连后中继会把同一个问题再问一次：已经在等的就不重复弹
                    if buffer.approval?.req != req {
                        speaking.insert(convo.id)
                        withAnimation(Motion.bubble) { buffer.approval = PendingApproval(req: req, text: text) }
                        // 不在这个聊天里（或者 App 在后台）：提醒你去点
                        notify(convo: convo, persona: persona, text: String(localized: "想\(text)，等你确认"))
                    }
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
                    if (!buffer.text.trimmed.isEmpty && !buffer.hold) || !buffer.steps.isEmpty {
                        speaking.insert(convo.id)
                        // 边写边显示的认真回答：新的开始出字了，旧的那条退场
                        if replacing[convo.id] != nil { withAnimation(Motion.bubble) { retireReplaced(convo.id, context: context) } }
                    }
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
                context.persist()
                return
            }
            buffer.text += pendingText
            buffer.reasoning += pendingReasoning
            // 被你插话打断了：还藏着没显示的半段话直接丢掉
            if Task.isCancelled { throw CancellationError() }
            await commitParagraphs()
            if buffer.text.trimmed.isEmpty && sent.isEmpty && !Task.isCancelled { throw RelayError.server("没有收到回复。") }
            // 最后一条也按打字节奏出现（只有一句话的回复，犹豫也在这里）
            if !rich && !buffer.text.trimmed.isEmpty {
                if sent.isEmpty { await hesitate() }
                await pace(for: buffer.text)
            }
            if !rich { lastAudio = await record(buffer.text) }
            if buffer.hold { message.createdAt = max(.now, message.createdAt) }
            buffer.hold = false
            message.status = .done
        } catch {
            if (Task.isCancelled || error is CancellationError) && buffer.hold && pending[convo.id] != nil {
                // 你插话打断了还没开口的 TA：这个「正在输入」留着，TA 看完你的新消息接着在里面打
                buffer.text = ""
                buffer.reasoning = ""
                carried[convo.id] = message
                return
            }
            if Task.isCancelled || error is CancellationError {
                message.status = .done
                if buffer.hold { buffer.text = "" }
            } else {
                message.status = .error
                message.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        let final = message.status == .done
            ? applyMarkers(buffer.text.trimmed, to: message, persona: persona, convo: convo, context: context)
            : buffer.text.trimmed
        // 重新生成出错了、新的一句也没说出来：失败的这条不要，原来那条留着，只提示一下
        let failedRedo = message.status == .error && replacing[convo.id] != nil
        let saidSomething = message.status == .done && (!final.isEmpty || !buffer.steps.isEmpty)
        // 最后一句也和前面一样：小点变成文字、气泡撑开，在同一个平滑动画里完成
        withAnimation(Motion.bubble) {
            buffers[message.id] = nil
            message.content = final
            message.reasoning = buffer.reasoning.trimmed
            message.steps = buffer.steps.joined(separator: "\n")
            if failedRedo || (message.status == .done && message.content.isEmpty && message.steps.isEmpty) {
                context.delete(message)
            } else if message.status == .done, let lastAudio {
                attach(lastAudio, to: message)
            }
            if saidSomething { retireReplaced(convo.id, context: context) }
        }
        // 没换成（出错、被你停下）：原来那条照旧留着
        replacing[convo.id] = nil
        if failedRedo { redoFailed.insert(convo.id) }
        if !final.isEmpty && message.status == .done {
            sent.append(lastAudio == nil ? final : "[语音]")
        }
        if let last = sent.last {
            notify(convo: convo, persona: persona, text: last)
        }
        convo.updatedAt = .now
        if router?.openConversation == convo.id { convo.lastReadAt = .now }
        context.persist()
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
        // TA 提起自己的动态：消息上附上 TA 最近那条
        if markers.moment, let latest = context.visibleMoments(by: persona.id).first { message.momentID = latest.id }
        // 换了称呼、闹别扭、和好
        HumanTouch.apply(markers, persona: persona)
        // 一起听时 TA 点了一首：排在下一首
        if let song = markers.song, !song.isEmpty { ListenTogether.shared.request(song) }
        // 心声：开了「内心想法」才留着，显示在这条气泡上方
        if let thought = markers.thought, !thought.isEmpty, HumanTouch.thoughts(persona) {
            Cleanup.saveThought(String(thought.prefix(Limits.Prompt.thought)), for: message.id, context: context)
        }
        // TA 拍了拍你：跟在这句后面一行小字
        if markers.pat { patBack(persona, in: convo, context: context, after: message.createdAt) }
        // TA 看了你发的表情：记下它是什么样（写在你那条表情消息里，界面上不显示，聊天记录里 TA 下次就知道）
        if let note = markers.stickerNote, !note.isEmpty,
           let sticker = convo.visibleMessages().last(where: { $0.role == .user && $0.kind == .sticker && $0.content.isEmpty }) {
            sticker.content = String(note.prefix(40))
        }
        // TA 分享相册里的一张照片：单独一条图片消息，跟在这句话后面
        if let number = markers.photo, let photo = HumanTouch.takePhoto(number, persona: persona, context: context) {
            let picture = Message(role: .assistant, kind: .images, content: "", personaID: persona.id)
            picture.createdAt = max(.now, message.createdAt).addingTimeInterval(0.000005)
            let a = Attachment(kind: .image, fileName: "photo.jpg", data: photo.data, order: 0)
            withAnimation(Motion.bubble) {
                convo.add(picture, context: context)
                a.message = picture
                context.insert(a)
            }
        }
        let stickers = markers.stickerPacks.isEmpty ? [] : (try? context.fetch(FetchDescriptor<Sticker>())) ?? []
        for pack in markers.stickerPacks {
            // 找不到这个分类就不发
            guard let pick = stickers.filter({ $0.pack == pack }).randomElement() else { continue }
            let sticker = Message(role: .assistant, kind: .sticker, content: "", personaID: persona.id)
            sticker.createdAt = max(.now, message.createdAt).addingTimeInterval(0.00001)
            let a = Attachment(kind: .image, fileName: "sticker.png", data: pick.data, order: 0)
            withAnimation(Motion.bubble) {
                convo.add(sticker, context: context)
                a.message = sticker
                context.insert(a)
            }
        }
        return markers.body
    }

    /// 电脑发回来的文件：图片显示成照片，其他显示成文件卡片。名字先清理成单纯的文件名（FileName）
    func deliver(file rawName: String, data: Data, from persona: Persona, in convo: Conversation, context: ModelContext) {
        let name = FileName.safe(rawName)
        let ext = (name as NSString).pathExtension.lowercased()
        let isImage = ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext)
        let m = Message(role: .assistant, kind: isImage ? .images : .file, content: "", personaID: persona.id)
        let a = Attachment(kind: isImage ? .image : .file, fileName: name, data: data, order: 0)
        withAnimation(Motion.bubble) {
            convo.add(m, context: context)
            a.message = m
            context.insert(a)
        }
        context.persist()
    }

    /// 回复好了：在别的页面时顶部滑下提示；App 在后台时发系统通知
    private func notify(convo: Conversation, persona: Persona, text: String) {
        let title = PlannedMessages.title(persona, in: convo)
        if UIApplication.shared.applicationState != .active {
            Reminders.notifyReply(conversationID: convo.id, title: title, body: text)
            return
        }
        guard router?.openConversation != convo.id else { return }
        banners?.show(.init(conversationID: convo.id, title: title, body: text, tint: persona.tint, initial: persona.initial))
    }
}
