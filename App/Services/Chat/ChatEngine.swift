import Foundation
import SwiftData
import Observation
import SwiftUI
import UIKit

/// 聊天引擎：你说话以后谁来回、什么时候回、怎么一句一句冒出来。
/// 这个文件放状态和一轮回复的进程；其余按功能分在扩展里：
/// `+Send`（发送、撤回重看、拍一拍、重新生成）、`+Late`（晚回和断线时排队的消息）、`+Group`（谁来回、潜水）、
/// `+Bubbles`（「正在输入」的气泡）、`+Markers`（回复里的小标记、发回的文件、通知）、`+Recover`、`+Translate`；
/// 一次回复本身在 `ReplySession`
@MainActor
@Observable
final class ChatEngine {
    // MARK: - 状态
    // 下面这些只由 ChatEngine、它的扩展和 ReplySession 改；界面只读

    var buffers: [UUID: StreamBuffer] = [:]
    /// 对话 ID -> 正在回复的角色 ID
    var typing: [UUID: UUID] = [:]
    var busy: Set<UUID> = []
    /// 正在翻译的消息（下面显示「翻译中…」，见 ChatEngine+Translate）
    var translating: Set<UUID> = []
    @ObservationIgnored var tasks: [UUID: Task<Void, Never>] = [:]
    /// 回复途中用户又发了消息：等这一轮说完（或直接打断）后，再按新的上下文回复
    @ObservationIgnored var pending: [UUID: [Persona]] = [:]
    /// 这一轮回复是不是已经开始出字了
    @ObservationIgnored var speaking: Set<UUID> = []
    /// TA 正在打字时被你插话：那个「正在输入」的气泡留着，TA 看完你的新消息接着在里面打（对话 ID -> 那条消息）
    @ObservationIgnored var carried: [UUID: Message] = [:]
    /// 重新生成：要被换掉的那条旧回复（对话 ID -> 消息）。新的说出第一句才拿掉它；没换成就一直留着
    @ObservationIgnored var replacing: [UUID: Message] = [:]
    /// 要在聊天页轻轻提示一句的事（对话 ID -> 那句话）：聊天页看到后提示，然后清掉
    var notices: [UUID: String] = [:]
    /// 语音服务出了要你处理的问题（额度用完、密钥不对）：每次打开 App 只提醒一次，不每句都提醒
    @ObservationIgnored var voiceWarned = false
    /// 重新生成没成功的对话：聊天页看到后提示一句「原来的回复还在」，然后清掉
    var redoFailed: Set<UUID> = []
    /// 切到后台时向系统多要一点时间，让正在进行的回复写完
    @ObservationIgnored private var background: [UUID: UIBackgroundTaskIdentifier] = [:]
    /// 正在取回中断的回复（见 ChatEngine+Recover），避免同时取两遍
    @ObservationIgnored var recovering = false
    /// TA 在忙、晚点才回（见 HumanTouch.lateness）：正在写的那次、为什么忙
    @ObservationIgnored var latePlans: [UUID: HumanTouch.Late] = [:]
    @ObservationIgnored var lateTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var lateReasons: [UUID: String] = [:]
    /// 回拍、记忆整理、补一句这些小任务（对话 ID → 任务），见 keep
    @ObservationIgnored private var sideTasks: [UUID: [UUID: Task<Void, Never>]] = [:]
    /// 电脑没连上时排队的提示：每次打开 App 只说一次
    @ObservationIgnored var queuedNoticeShown = false
    /// 中继（测试里是假中继，见 RelayTransport）
    @ObservationIgnored private(set) weak var relay: (any RelayTransport)?
    @ObservationIgnored private(set) weak var banners: BannerCenter?
    @ObservationIgnored private(set) weak var router: Router?

    func attach(relay: any RelayTransport, banners: BannerCenter?, router: Router?) {
        self.relay = relay
        self.banners = banners
        self.router = router
    }

    func isBusy(_ convo: Conversation) -> Bool { busy.contains(convo.id) }

    // MARK: - 停下

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
    func keep(_ convoID: UUID, _ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        sideTasks[convoID, default: [:]][id] = Task { [weak self] in
            await work()
            self?.sideTasks[convoID]?[id] = nil
        }
    }

    // MARK: - 一轮回复

    func run(_ responders: [Persona], in convo: Conversation, members: [Persona], context: ModelContext,
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
            await self?.speakInTurn(responders, rounds: rounds, in: convo, members: members, context: context)
            self?.endTurn(responders, in: convo, members: members, context: context)
        }
    }

    /// 一个一个回：群里换人回时停一小会儿；有人在话里 @ 了别人，被 @ 的人接着回
    private func speakInTurn(_ responders: [Persona], rounds: Int, in convo: Conversation, members: [Persona],
                             context: ModelContext) async {
        let convoID = convo.id
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
                guard !Task.isCancelled, pending[convoID] == nil else { break rounds }
                await reply(as: persona, in: convo, members: members, context: context, discussing: round > 0)
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
    }

    /// 这一轮说完：你中途又说了话就接着回；否则收尾，在后台整理记忆、偶尔补一句
    private func endTurn(_ responders: [Persona], in convo: Conversation, members: [Persona], context: ModelContext) {
        let convoID = convo.id
        busy.remove(convoID)
        speaking.remove(convoID)
        typing[convoID] = nil
        tasks[convoID] = nil
        if let next = pending.removeValue(forKey: convoID) {
            // 回复途中你又说了话：接着按最新的聊天回复
            run(next, in: convo, members: members, context: context, react: true)
            return
        }
        dropCarried(convoID, context: context)
        releaseBackground(convoID)
        // 被停下了（清空聊天、删除）：不再整理记忆、不补一句
        guard !Task.isCancelled else { return }
        // 聊得够多了，就在后台把更早的部分整理进长期记忆
        if let relay {
            keep(convoID) { await Memory.updateIfNeeded(convo, members: members, context: context, relay: relay) }
            // 偶尔过几分钟又想起来补一句（单聊）
            if !convo.isGroup, let persona = responders.first {
                keep(convoID) { await HumanTouch.maybeAfterthought(persona: persona, convo: convo, context: context, relay: relay) }
            }
        }
    }

    /// TA 开始看你的消息了：你发的消息显示已读双勾
    func markRead(_ convo: Conversation, context: ModelContext) {
        let now = Date.now
        var changed = false
        // 晚回「没看到」时已读排在以后；改成现在就回了，已读也提前到现在
        for m in convo.messages ?? [] where m.role == .user && (m.readAt ?? .distantFuture) > now && m.createdAt <= now {
            m.readAt = now
            changed = true
        }
        if changed { context.persist() }
    }

    // MARK: - 后台时间

    func holdBackground(_ id: UUID) {
        guard background[id] == nil else { return }
        background[id] = UIApplication.shared.beginBackgroundTask(withName: "reply") { [weak self] in
            Task { @MainActor in self?.releaseBackground(id) }
        }
    }

    func releaseBackground(_ id: UUID) {
        guard let task = background.removeValue(forKey: id), task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
    }
}
