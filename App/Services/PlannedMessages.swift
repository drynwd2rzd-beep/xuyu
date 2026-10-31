import Foundation
import SwiftData

/// 提前写好、到点才出现的消息（主动消息、追问、晚回、补一句、视频分享、约定）：只在这里排、只在这里撤（CONC-5）。
/// 排 = 插进聊天（createdAt 是到点的时间）+ 存盘 + 排一个到点的本地通知；撤 = 撤通知 + 删消息
@MainActor
enum PlannedMessages {
    /// 计划消息的记号，存在 Message.relayID 里（存的字符串不能改，DATA-5）
    enum Marker: String {
        /// 主动消息、追问
        case plain = ""
        /// 晚回：TA 看到了只是没空回 / 根本没看到
        case lateRead = "late-read"
        case lateUnread = "late-unread"
        /// TA 刷到的视频（卡片见 VideoCards）
        case video
        /// 想起来再补一句
        case afterthought

        /// 约定的消息靠 Appointments 里记的 messageID 认出来，不另打记号
        static let appointment = Marker.plain

        var isLate: Bool { self == .lateRead || self == .lateUnread }
    }

    /// 排一条：到 date 才出现在聊天里，到点弹通知（notify 为 false 时不排通知，比如晚回分成几条时只有第一条响）
    @discardableResult
    static func plan(_ text: String, by persona: Persona, in convo: Conversation, at date: Date,
                     marker: Marker = .plain, notify: Bool = true, context: ModelContext) -> Message {
        let m = Message(role: .assistant, content: text, personaID: persona.id)
        m.isProactive = true
        m.relayID = marker.rawValue
        m.createdAt = date
        convo.add(m, context: context)
        context.persist()
        if notify {
            Reminders.scheduleProactive(messageID: m.id, conversationID: convo.id, title: title(persona, in: convo), body: text, at: date)
        }
        return m
    }

    /// 通知和横幅的标题：群聊里是「群名 · 角色名」
    static func title(_ persona: Persona, in convo: Conversation) -> String {
        convo.isGroup ? "\(convo.title.isEmpty ? String(localized: "群聊") : convo.title) · \(persona.name)" : persona.name
    }

    /// 这条消息的记号
    static func marker(of m: Message) -> Marker? { Marker(rawValue: m.relayID) }

    /// 撤掉一条：撤通知、删消息。存盘由调用的一方做
    static func cancel(_ m: Message, context: ModelContext) {
        Reminders.cancelProactive(messageID: m.id)
        context.delete(m)
    }

    /// 你先开口了（发消息、拍一拍）：撤掉这个聊天里还没到点的，约定照原时间来（CONC-5 第 5 条）
    static func cancelForYourTurn(in convo: Conversation, context: ModelContext) {
        for m in convo.plannedMessages() where !Appointments.isAppointment(m.id) { cancel(m, context: context) }
    }

    /// 某个时间以后排好的（追问要插在前面时，后面的主动消息是在不知道追问时写的），约定除外
    static func cancelLater(than date: Date, in convo: Conversation, context: ModelContext) {
        for m in convo.plannedMessages(after: date) where !Appointments.isAppointment(m.id) { cancel(m, context: context) }
    }

    /// 清空、删除时：这个聊天里还没到点的全部撤掉，约定的也撤（CONC-9）
    static func cancelAll(in convo: Conversation, context: ModelContext) {
        for m in convo.plannedMessages() { cancel(m, context: context) }
    }
}
