import Foundation
import SwiftData

/// 你和 TA 的约定：「晚上找我」「半小时后提醒我」「每天 22:30 催我睡觉」
struct Appointment: Codable, Identifiable, Equatable {
    var id = UUID()
    var personaID: UUID
    var conversationID: UUID
    /// 要做的事，比如「催睡觉」
    var what: String
    /// 下一次的时间
    var at: Date
    /// 每天这个时候都来
    var daily = false
    /// 已经排好的那条消息（到点才出现）
    var messageID: UUID?
    /// 那条消息是什么时候写的：之后你们又聊过，就按新的聊天重写
    var writtenAt: Date?
}

/// TA 答应你的事，到点真的来：TA 回复时带一个看不见的【约定:时间|事情】，
/// App 提前写好那条消息、排在约定的时间，到点出现在聊天里并发通知（App 关着也能收到）
@MainActor
enum Appointments {
    // MARK: - 存取（存在本机设置里，会跟着备份走）

    static var all: [Appointment] {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Prefs.appointments), let data = raw.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([Appointment].self, from: data)) ?? []
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data()
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: Prefs.appointments)
        }
    }

    static func isAppointment(_ messageID: UUID) -> Bool {
        all.contains { $0.messageID == messageID }
    }

    /// 这位角色在这个聊天里的约定，给 TA 看的一行一条：「每天 22:30 催睡觉」
    static func summary(persona: Persona, convo: Conversation) -> String {
        all.filter { $0.personaID == persona.id && $0.conversationID == convo.id }
            .map { "- \(label(for: $0))" }
            .joined(separator: "\n")
    }

    /// 「每天 22:30 催睡觉」「10月28日 08:00 叫我起床」
    static func label(for a: Appointment) -> String {
        let when = a.daily ? "每天 " + Fmt.time24.string(from: a.at)
            : Calendar.current.isDateInToday(a.at) ? "今天 " + Fmt.time24.string(from: a.at)
            : Fmt.md.string(from: a.at) + " " + Fmt.time24.string(from: a.at)
        return "\(when) \(a.what)"
    }

    // MARK: - 认时间

    /// 认出标记里的时间：「21:30」（今天，过了就是明天）、「明天 08:00」「后天 9:00」、「2026-10-28 08:00」、
    /// 「+30分钟」「+2小时」，前面加「每天」就是每天都来
    nonisolated static func parseTime(_ text: String, now: Date) -> (date: Date, daily: Bool)? {
        var s = text.trimmed.replacingOccurrences(of: "：", with: ":")
        let daily = s.hasPrefix("每天")
        if daily { s = String(s.dropFirst(2)).trimmed }
        let cal = Calendar.current

        if let m = s.firstMatch(of: #/^\+\s*(\d+)\s*(分钟|分|小时|个小时|时|min|h)$/#), let n = Double(m.1) {
            let unit = m.2.hasPrefix("分") || m.2 == "min" ? 60.0 : 3600.0
            return (now.addingTimeInterval(n * unit), false)
        }
        if let m = s.firstMatch(of: #/^(\d{4})-(\d{1,2})-(\d{1,2})\s+(\d{1,2}):(\d{2})$/#),
           let date = cal.date(from: DateComponents(year: Int(m.1), month: Int(m.2), day: Int(m.3), hour: Int(m.4), minute: Int(m.5))) {
            return (date, daily)
        }
        var offset = 0
        if s.hasPrefix("明天") { offset = 1; s = String(s.dropFirst(2)).trimmed }
        else if s.hasPrefix("后天") { offset = 2; s = String(s.dropFirst(2)).trimmed }
        guard let m = s.firstMatch(of: #/^(\d{1,2}):(\d{2})$/#), let h = Int(m.1), let min = Int(m.2), h < 24, min < 60,
              var date = cal.date(bySettingHour: h, minute: min, second: 0, of: now.startOfDay.adding(days: offset)) else { return nil }
        if offset == 0 && date <= now { date = date.adding(days: 1) }
        return (date, daily)
    }

    // MARK: - 答应 / 取消

    /// TA 答应了：记下约定，提前写好到点要发的那条消息
    static func promise(_ p: ReplyText.Promise, persona: Persona, convo: Conversation, context: ModelContext, relay: RelayClient?) {
        guard let time = parseTime(p.time, now: .now), !p.what.isEmpty else { return }
        // 同一件事再约一次：以新的为准
        cancel(p.what, persona: persona, convo: convo, context: context)
        let appointment = Appointment(personaID: persona.id, conversationID: convo.id, what: p.what, at: time.date, daily: time.daily)
        all.append(appointment)
        guard let relay else { return }
        Task { await write(appointment.id, context: context, relay: relay) }
    }

    /// 不用了：撤掉这件事的约定和排好的消息
    static func cancel(_ what: String, persona: Persona, convo: Conversation, context: ModelContext) {
        let key = what.trimmed
        guard !key.isEmpty else { return }
        let gone = all.filter { $0.personaID == persona.id && $0.conversationID == convo.id && ($0.what.contains(key) || key.contains($0.what)) }
        for a in gone { remove(a, context: context) }
    }

    /// 删掉一个约定（角色页里也能删）
    static func remove(_ appointment: Appointment, context: ModelContext) {
        if let id = appointment.messageID { dropMessage(id, context: context) }
        all.removeAll { $0.id == appointment.id }
    }

    // MARK: - 维护：App 打开时、每隔一会儿检查一次

    static func refresh(context: ModelContext, relay: RelayClient) async {
        let now = Date.now
        for var a in all {
            if a.at <= now {
                // 已经送到了：每天的就排到下一天，一次性的就结束
                guard a.daily else { all.removeAll { $0.id == a.id }; continue }
                while a.at <= now { a.at = a.at.adding(days: 1) }
                a.messageID = nil
                a.writtenAt = nil
                update(a)
            }
            let message = a.messageID.flatMap { id in try? context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })).first }
            if message == nil {
                await write(a.id, context: context, relay: relay)
            } else if let written = a.writtenAt, let convo = message?.conversation,
                      let last = convo.lastVisible(at: now), last.createdAt > written,
                      a.at.timeIntervalSince(now) > 120, a.at.timeIntervalSince(now) < 6 * 3600 {
                // 写好之后你们又聊过了：快到点时按新的聊天重写，接得上刚才的话
                await write(a.id, context: context, relay: relay)
            }
        }
    }

    // MARK: - 写那条消息

    private static func write(_ id: UUID, context: ModelContext, relay: RelayClient) async {
        guard !DemoMode.isOn, var a = all.first(where: { $0.id == id }), let persona = context.persona(a.personaID) else { return }
        let convoID = a.conversationID
        guard let convo = try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == convoID })).first else { return }
        let names = Dictionary(context.allPersonas().map { ($0.id, $0.name) }, uniquingKeysWith: { x, _ in x })
        let memory = convo.memory.trimmed
        let user = PromptBuilder.userName
        let prompt = """
        \(memory.isEmpty ? "" : "你记得的关于\(user)的事：\n\(memory)\n\n")下面是你们最近的聊天记录：

        \(PromptBuilder.transcript(Array(convo.visibleMessages().suffix(20)), names: names))

        你答应过\(user)：\(Fmt.full.string(from: a.at)) 来\(a.what)。现在就是那个时间，写你这时要发给 TA 的那条消息：说到做到，自然、口语化，接得上你们聊过的事，一两句话。只输出消息内容。
        """
        guard let text = try? await relay.complete(Companion.lightRequest(persona, prompt)), !text.trimmed.isEmpty,
              all.contains(where: { $0.id == id }) else { return }
        if let old = a.messageID { dropMessage(old, context: context) }
        let body = ReplyText.markers(in: text).body.trimmed
        guard !body.isEmpty else { return }
        let message = Message(role: .assistant, content: body, personaID: persona.id)
        message.isProactive = true
        message.createdAt = a.at
        convo.add(message, context: context)
        context.persist()
        let title = convo.isGroup ? "\(convo.title.isEmpty ? "群聊" : convo.title) · \(persona.name)" : persona.name
        Reminders.scheduleProactive(messageID: message.id, conversationID: convo.id, title: title, body: body, at: a.at)
        a.messageID = message.id
        a.writtenAt = .now
        update(a)
    }

    private static func update(_ a: Appointment) {
        var list = all
        if let i = list.firstIndex(where: { $0.id == a.id }) { list[i] = a }
        all = list
    }

    /// 撤掉还没到点的那条消息（已经出现在聊天里的就留着）
    private static func dropMessage(_ id: UUID, context: ModelContext) {
        Reminders.cancelProactive(messageID: id)
        guard let m = try? context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })).first, m.createdAt > .now else { return }
        context.delete(m)
        context.persist()
    }
}
