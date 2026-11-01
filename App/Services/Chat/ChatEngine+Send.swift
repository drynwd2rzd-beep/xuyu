import Foundation
import SwiftData
import SwiftUI
import UIKit

// MARK: - 你说话：发送、撤回重看、拍一拍、重新生成

extension ChatEngine {
    /// 你说了一次话。照片和文件一起发时分成两条（照片带着文字一条、文件一条），但只算一次，按这句话决定谁来回
    func send(_ text: String, kind: MessageKind = .text, attachments: [OutgoingAttachment] = [], quote: String = "", quoteID: UUID? = nil,
              in convo: Conversation, members: [Persona], context: ModelContext) {
        addOutgoing(text, kind: kind, attachments: attachments, quote: quote, quoteID: quoteID, in: convo, context: context)
        convo.updatedAt = .now
        convo.lastReadAt = .now
        // TA 正在忙、晚回的那几条已经排好了：你又说了话，按同一个时间重新写（把你新说的也回了），TA 不会因为你多发几条就突然有空
        let carriedLate = latePlans[convo.id] ?? lateMessages(in: convo).min(by: { $0.createdAt < $1.createdAt }).map {
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
        let responders = Self.whoAnswers(text, convo: convo, members: members)
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

    /// 把你说的话放进聊天：照片和文件一起发时分成两条
    private func addOutgoing(_ text: String, kind: MessageKind, attachments: [OutgoingAttachment], quote: String, quoteID: UUID?,
                             in convo: Conversation, context: ModelContext) {
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

    /// 拍一拍：你双击了 TA 的头像。TA 有时回拍你一下，有时看到「你拍了拍 TA」回一句
    func nudge(_ persona: Persona, in convo: Conversation, members: [Persona], context: ModelContext) {
        let m = Message(role: .user, kind: .nudge, content: persona.name)
        withAnimation(Motion.bubble) { convo.add(m, context: context) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        convo.updatedAt = .now
        convo.lastReadAt = .now
        // TA 正在忙、晚点回的那几条已经排好了：拍一拍不会让 TA 突然有空，只留下这一行，TA 到点再回
        if latePlans[convo.id] != nil || !lateMessages(in: convo).isEmpty {
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
    func patBack(_ persona: Persona, in convo: Conversation, context: ModelContext, after: Date) {
        let m = Message(role: .assistant, kind: .nudge, content: "", personaID: persona.id)
        m.createdAt = max(.now, after).addingTimeInterval(0.000008)
        withAnimation(Motion.bubble) { convo.add(m, context: context) }
        context.persist()
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
}
