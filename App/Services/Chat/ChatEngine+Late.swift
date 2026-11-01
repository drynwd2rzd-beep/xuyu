import Foundation
import SwiftData
import SwiftUI

// MARK: - 晚回和断线时排队的消息

extension ChatEngine {
    /// 这个对话里已经排好的晚回（TA 在忙、晚点才回的那几条）。发送、排队回复、拍一拍都按它判断，只写这一份（审查 Z-274）
    func lateMessages(in convo: Conversation) -> [Message] {
        convo.plannedMessages().filter { PlannedMessages.marker(of: $0)?.isLate == true }
    }

    /// TA 在忙：看到了就先显示已读、过一阵再回；没看到就一直未读，到回的时候才算看过。
    /// 回复先写好、排在那个时间出现（App 关着也会到点弹通知）；没写成就照常马上回
    func planLate(_ late: HumanTouch.Late, persona: Persona, convo: Conversation, members: [Persona],
                  context: ModelContext, relay: any RelayTransport) {
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
            guard lateMessages(in: convo).isEmpty else { continue }
            let members = convo.memberIDs.compactMap { id in personas.first { $0.id == id } }
            guard !members.isEmpty else { continue }
            let unanswered = said.reversed().prefix { $0.role == .user }.filter { !$0.recalled }
            let responders = Self.whoAnswers(unanswered.map(\.content).joined(separator: "\n"), convo: convo, members: members)
            guard let persona = responders.first else { continue }
            if let late = HumanTouch.lateness(for: persona, convo: convo) {
                planLate(late, persona: persona, convo: convo, members: members, context: context, relay: relay)
            } else {
                run(responders, in: convo, members: members, context: context, react: true)
            }
        }
    }
}
