import Foundation
import Observation
import SwiftData
import SwiftUI

/// 正在写哪几天的日记：待办页据此显示「正在写…」
@MainActor
@Observable
final class DiaryState {
    static let shared = DiaryState()
    var writing: Set<Date> = []
    /// 正在给你的哪篇日记回信
    var replying: Set<UUID> = []
}

/// 让 AI 像朋友一样「在」：今日一句、每天的日记、主动发来的消息。
/// 都在 App 打开时提前生成；主动消息排成本地通知，到点送达。
@MainActor
enum Companion {
    private static var running = false

    static func refresh(context: ModelContext, relay: RelayClient) async {
        guard !running, !DemoMode.isOn else { return }
        running = true
        defer { running = false }
        relay.connectIfConfigured()
        try? await Task.sleep(for: .seconds(1.5))
        guard relay.isConnected else { return }
        let personas = context.allPersonas()
        guard let main = personas.first else { return }
        await whisper(context: context, relay: relay, persona: main)
        await writeDiaries(context: context, relay: relay)
        await followUps(context: context, relay: relay, personas: personas)
        await proactive(context: context, relay: relay, personas: personas)
        await Appointments.refresh(context: context, relay: relay)
        Reminders.syncDiaryReminder()
        await Backup.autoBackupIfNeeded(context: context, relay: relay)
    }

    // MARK: - 没回消息会来追问

    /// 追问的等待时间：1 = 20 分钟～1 小时，2 = 1～3 小时，3 = 3～6 小时（0 = 不追问）
    static func followUpRange(_ setting: Int) -> ClosedRange<Double> {
        switch setting {
        case 2: 3600...10800
        case 3: 10800...21600
        default: 1200...3600
        }
    }

    /// 切到后台和定时刷新可能同时触发：同一时间只准备一次，避免追问两遍
    private static var followingUp = false

    /// 最后一条是 TA 发的、你一直没回：过一阵子 TA 会来问你怎么不回了，或者接着刚才的话题。每段话题只追问一次
    static func followUps(context: ModelContext, relay: RelayClient, personas: [Persona]) async {
        guard !DemoMode.isOn, relay.isConnected, !followingUp else { return }
        followingUp = true
        defer { followingUp = false }
        let now = Date.now
        for persona in personas where persona.followUp > 0 {
            let convo = context.chat(for: persona)
            let visible = convo.visibleMessages(at: now)
            guard let last = visible.last, last.role == .assistant, last.status == .done, !last.isProactive,
                  now.timeIntervalSince(last.createdAt) < 12 * 3600 else { continue }
            let range = followUpRange(persona.followUp)
            // 这段话题的追问时间附近已经排了消息（上次准备好的追问）就不再排；
            // 更远的主动消息（比如明天的）不算，不然开了「主动找我聊天」就永远等不到追问
            let horizon = max(last.createdAt.addingTimeInterval(range.upperBound), now).addingTimeInterval(3600)
            guard !convo.plannedMessages(after: now).contains(where: { $0.createdAt <= horizon }) else { continue }
            var deliver = last.createdAt.addingTimeInterval(Double.random(in: range))
            // 已经过了该追问的时间（比如刚打开 App）：过两三分钟再来
            if deliver < now.addingTimeInterval(90) { deliver = now.addingTimeInterval(Double.random(in: 120...300)) }
            guard !Prefs.isQuiet(deliver) else { continue }
            let names = [persona.id: persona.name]
            let memory = convo.memory.trimmed
            let gap = Fmt.duration(deliver.timeIntervalSince(last.createdAt))
            let prompt = """
            \(memory.isEmpty ? "" : "你记得的关于\(PromptBuilder.userName)的事：\n\(memory)\n\n")下面是你们最近的聊天记录：

            \(PromptBuilder.transcript(Array(visible.suffix(20)), names: names))

            你最后发的那条，\(PromptBuilder.userName)已经过了\(gap)还没回。像真人朋友一样再发一条：可以俏皮或关心地问 TA 怎么不回消息、是不是在忙，或者接着刚才没聊完的话题再说一句。一两句话，口语化，不要重复你上一条说过的话。只输出消息内容。
            """
            guard let text = try? await relay.complete(lightRequest(persona, prompt)), !text.trimmed.isEmpty else { continue }
            // 生成的这段时间里你回了消息：就不用追问了
            guard convo.visibleMessages().last?.id == last.id else { continue }
            // 之后排好的主动消息是在不知道这条追问时写的，撤掉，等追问送达后再重新安排
            for later in convo.plannedMessages(after: deliver) where !Appointments.isAppointment(later.id) {
                Reminders.cancelProactive(messageID: later.id)
                context.delete(later)
            }
            let message = Message(role: .assistant, content: text.trimmed, personaID: persona.id)
            message.isProactive = true
            message.createdAt = deliver
            message.conversation = convo
            context.insert(message)
            try? context.save()
            Reminders.scheduleProactive(messageID: message.id, conversationID: convo.id,
                                        title: persona.name, body: text.trimmed, at: deliver)
        }
    }

    /// 日记由你在待办页选的那位角色来写，没选就是第一位。待办页打开时、以及 App 开着时每隔一会儿都会检查一次
    static func writeDiaries(context: ModelContext, relay: RelayClient) async {
        guard !DemoMode.isOn, relay.isConnected else { return }
        let personas = context.allPersonas()
        let writerID = UserDefaults.standard.string(forKey: Prefs.diaryWriter).flatMap(UUID.init(uuidString:))
        guard let writer = personas.first(where: { $0.id == writerID }) ?? personas.first else { return }
        await diaries(context: context, relay: relay, persona: writer)
    }

    // MARK: - 交换日记

    /// 你写完日记后，写日记的那位角色回一小段话，像交换日记一样
    static func replyToDiary(_ entry: DiaryEntry, by persona: Persona, context: ModelContext, relay: RelayClient) async {
        guard !DemoMode.isOn, !DiaryState.shared.replying.contains(entry.id) else { return }
        let text = entry.text.trimmed
        guard !text.isEmpty else { return }
        DiaryState.shared.replying.insert(entry.id)
        defer { DiaryState.shared.replying.remove(entry.id) }
        let convo = context.chat(for: persona)
        let recent = Array(convo.visibleMessages().suffix(20))
        let memory = convo.memory.trimmed
        let prompt = """
        \(memory.isEmpty ? "" : "你记得的关于\(PromptBuilder.userName)的事：\n\(memory)\n\n")\(recent.isEmpty ? "" : "你们最近的聊天：\n\(PromptBuilder.transcript(recent, names: [persona.id: persona.name]))\n\n")\(PromptBuilder.userName)在 \(Fmt.md.string(from: entry.day)) 写了一篇日记\(entry.mood.isEmpty ? "" : "（心情：\(entry.mood)）")：
        \(text)

        你们在交换日记。请以「\(persona.name)」的身份，在 TA 的日记下面回一小段话：真诚、温柔、具体地回应 TA 写的事和心情，可以接着聊或轻轻鼓励，不要说教，不要复述原文，60 到 120 字。只输出回信内容。
        """
        guard let reply = try? await relay.complete(lightRequest(persona, prompt)), !reply.trimmed.isEmpty else { return }
        withAnimation(Motion.spring) {
            entry.reply = reply.trimmed
            entry.replyPersonaID = persona.id
            entry.repliedText = text
        }
        try? context.save()
    }

    /// 你最近几天写的日记，给聊天、主动消息和 TA 的日记当背景
    static func myDiaryNotes(context: ModelContext, days: Int = 3) -> String {
        let since = Date.now.startOfDay.adding(days: -(days - 1))
        let me = DiaryAuthor.me.rawValue
        let entries = (try? context.fetch(FetchDescriptor<DiaryEntry>(
            predicate: #Predicate { $0.authorRaw == me && $0.day >= since },
            sortBy: [SortDescriptor(\.day)]))) ?? []
        return entries.filter { !$0.text.trimmed.isEmpty || !$0.mood.isEmpty }.map { e in
            let body = e.text.trimmed.replacingOccurrences(of: "\n", with: " ")
            let short = body.count > 160 ? String(body.prefix(160)) + "…" : body
            return "- \(Fmt.md.string(from: e.day))\(e.mood.isEmpty ? "" : "（心情：\(e.mood)）")：\(short)"
        }.joined(separator: "\n")
    }

    /// 这一天的聊天够不够写日记
    static func enoughToWrite(on day: Date, context: ModelContext) -> Bool {
        messagesOn(day, context: context).count >= 3
    }

    // MARK: - 今日一句

    static var dayKey: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private static func whisper(context: ModelContext, relay: RelayClient, persona: Persona) async {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Prefs.whisperDay) != dayKey else { return }
        let todos = todayTodos(context).map(\.title).prefix(5).joined(separator: "、")
        let prompt = """
        今天是 \(Fmt.full.string(from: .now))。\(todos.isEmpty ? "" : "\(PromptBuilder.userName)今天的待办：\(todos)。")
        写一句今天想对\(PromptBuilder.userName)说的话：温柔、具体、有画面感，不超过 28 个字，可以用逗号分成两小句。不要引号，只输出这一句。
        """
        guard let text = try? await relay.complete(lightRequest(persona, prompt)), !text.isEmpty else { return }
        defaults.set(text.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "“", with: "").replacingOccurrences(of: "”", with: ""),
                     forKey: Prefs.whisperText)
        defaults.set(persona.name, forKey: Prefs.whisperAuthor)
        defaults.set(dayKey, forKey: Prefs.whisperDay)
    }

    // MARK: - 日记

    private static func diaries(context: ModelContext, relay: RelayClient, persona: Persona) async {
        let today = Date.now.startOfDay
        var days = [today.adding(days: -1)]
        if Calendar.current.component(.hour, from: .now) >= 20 { days.append(today) }
        // 今天：你选的那位还没写就写；昨天：谁都没写才补一篇
        let pending = days.filter { day in
            day == today ? aiDiary(on: day, by: persona, context: context) == nil
                : !((try? context.fetch(FetchDescriptor<DiaryEntry>(predicate: #Predicate { $0.day == day }))) ?? []).contains { $0.author == .ai }
        }
        for day in pending {
            let messages = messagesOn(day, context: context)
            let me = DiaryAuthor.me.rawValue
            let wroteOwn = ((try? context.fetchCount(FetchDescriptor<DiaryEntry>(predicate: #Predicate { $0.day == day && $0.authorRaw == me }))) ?? 0) > 0
            // 聊得够多，或者你自己写了日记，TA 就写
            guard messages.count >= 3 || wroteOwn else { continue }
            let names = Dictionary(context.allPersonas().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            let done = todosDone(on: day, context: context).map(\.title).joined(separator: "、")
            // TA 自己写的日记和心情：写日记时一起参考
            let mine = ((try? context.fetch(FetchDescriptor<DiaryEntry>(predicate: #Predicate { $0.day == day && $0.authorRaw == me }))) ?? []).first
            let mineLine = mine.map { e in
                "\(PromptBuilder.userName)这天自己也写了日记\(e.mood.isEmpty ? "" : "（心情：\(e.mood)）")：\(e.text.trimmed)\n"
            } ?? ""
            let prompt = """
            下面是 \(Fmt.md.string(from: day)) 你和\(PromptBuilder.userName)的聊天：

            \(PromptBuilder.transcript(Array(messages.suffix(80)), names: names))

            \(done.isEmpty ? "" : "这天完成的待办：\(done)。\n")\(mineLine)
            请以「\(persona.name)」的第一人称写这一天的日记，150 字左右，温柔真诚，写你们一起聊过的事和你的感受\(mine == nil ? "" : "，也可以写读了 TA 日记后的心情")，不要列清单。
            最后另起一行，只写：心情：两个字
            """
            DiaryState.shared.writing.insert(day)
            defer { DiaryState.shared.writing.remove(day) }
            guard let raw = try? await relay.complete(lightRequest(persona, prompt)), !raw.isEmpty else { continue }
            let (text, mood) = parseMood(raw)
            let entry = DiaryEntry(day: day, author: .ai, text: text, mood: mood)
            entry.personaID = persona.id
            context.insert(entry)
            try? context.save()
        }
    }

    static func parseMood(_ raw: String) -> (String, String) {
        var lines = raw.components(separatedBy: "\n")
        var mood = ""
        if let index = lines.lastIndex(where: { $0.contains("心情") }) {
            let line = lines[index]
            if let range = line.range(of: "心情[:：]\\s*", options: .regularExpression) {
                mood = String(line[range.upperBound...]).trimmed
                    .trimmingCharacters(in: CharacterSet(charactersIn: "。.!！「」\"*"))
                mood = String(mood.prefix(4))
            }
            lines.remove(at: index)
        }
        return (lines.joined(separator: "\n").trimmed, mood)
    }

    /// 某位角色在这一天写的日记（换了写日记的角色后，新角色会自己写一篇）
    static func aiDiary(on day: Date, by persona: Persona, context: ModelContext) -> DiaryEntry? {
        let start = day.startOfDay
        let entries = (try? context.fetch(FetchDescriptor<DiaryEntry>(predicate: #Predicate { $0.day == start }))) ?? []
        return entries.first { $0.author == .ai && $0.personaID == persona.id }
    }

    // MARK: - 主动消息

    private static func proactive(context: ModelContext, relay: RelayClient, personas: [Persona]) async {
        let now = Date.now
        let habits = activeHours(context: context)
        for persona in personas where persona.proactive {
            let convo = context.chat(for: persona)
            // 约好的消息不算：它们到点照常来
            guard convo.plannedMessages(after: now).allSatisfy({ Appointments.isAppointment($0.id) }) else { continue }
            let deliver = nextSlot(after: now, frequency: persona.proactiveFreq, habits: habits)
            let history = convo.visibleMessages(at: now)
            let names = [persona.id: persona.name]
            let todos = todayTodos(context).map(\.title).prefix(5).joined(separator: "、")
            let memory = convo.memory.trimmed
            let notes = myDiaryNotes(context: context)
            let prompt = """
            \(memory.isEmpty ? "" : "你记得的关于\(PromptBuilder.userName)的事：\n\(memory)\n\n")\(notes.isEmpty ? "" : "\(PromptBuilder.userName)最近写的日记：\n\(notes)\n\n")下面是你们最近的聊天记录：

            \(history.isEmpty ? "（还没有聊过）" : PromptBuilder.transcript(Array(history.suffix(20)), names: names))

            现在是 \(Fmt.full.string(from: now))。你打算在 \(Fmt.full.string(from: deliver)) 主动给\(PromptBuilder.userName)发一条消息。\(todos.isEmpty ? "" : "TA 最近的待办有：\(todos)。")
            像朋友一样自然地开个话题：可以接着之前聊的事、关心一下 TA、或者轻轻提醒一件事。一两句话，口语化，不要说「我来主动找你」。只输出消息内容。
            """
            guard let text = try? await relay.complete(lightRequest(persona, prompt)), !text.isEmpty else { continue }
            let message = Message(role: .assistant, content: text, personaID: persona.id)
            message.isProactive = true
            message.createdAt = deliver
            message.conversation = convo
            context.insert(message)
            try? context.save()
            Reminders.scheduleProactive(messageID: message.id, conversationID: convo.id,
                                        title: persona.name, body: text, at: deliver)
        }
    }

    /// 你平时几点爱聊天：最近 30 天你发的消息按小时数一数
    static func activeHours(context: ModelContext) -> [Int: Int] {
        let since = Date.now.adding(days: -30)
        let user = MessageRole.user.rawValue
        let messages = (try? context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.roleRaw == user && $0.createdAt >= since }))) ?? []
        var counts: [Int: Int] = [:]
        for m in messages { counts[Calendar.current.component(.hour, from: m.createdAt), default: 0] += 1 }
        return counts
    }

    /// 根据频率挑一个合适的时间：尽量落在你平时爱聊天的时段，避开免打扰和深夜
    static func nextSlot(after now: Date, frequency: Int, habits: [Int: Int] = [:]) -> Date {
        let hours: ClosedRange<Double> = switch frequency {
        case 0: 26...44
        case 2: 3...6
        default: 10...20
        }
        let cal = Calendar.current
        var date = now.addingTimeInterval(Double.random(in: hours) * 3600)
        // 聊天记录够多时，按你的习惯挑那一天里的某个钟点（聊得越多的钟点越容易被选中）
        let usable = habits.filter { $0.key >= 9 && $0.key < 22 && $0.value > 0 }
        if usable.values.reduce(0, +) >= 20 {
            let total = usable.values.reduce(0, +)
            var pick = Int.random(in: 0..<total)
            var hour = 20
            for (h, n) in usable.sorted(by: { $0.key < $1.key }) {
                if pick < n { hour = h; break }
                pick -= n
            }
            var candidate = date.startOfDay.addingTimeInterval(Double(hour) * 3600 + Double.random(in: 0..<3600))
            if candidate < now.addingTimeInterval(hours.lowerBound * 3600 * 0.6) { candidate = candidate.adding(days: 1) }
            date = candidate
        }
        for _ in 0..<4 {
            let h = cal.component(.hour, from: date)
            if h >= 9 && h < 22 && !Prefs.isQuiet(date) { break }
            let base = h >= 22 ? date.adding(days: 1).startOfDay : date.startOfDay
            date = base.addingTimeInterval(Double.random(in: 9.5...11.5) * 3600)
        }
        return date
    }

    /// 用户先说话了，就撤掉还没送达的主动消息
    static func cancelPlannedMessages(in convo: Conversation, context: ModelContext) {
        for m in convo.plannedMessages() where !Appointments.isAppointment(m.id) {
            Reminders.cancelProactive(messageID: m.id)
            context.delete(m)
        }
    }

    // MARK: - 工具

    static func lightRequest(_ persona: Persona, _ prompt: String) -> RelayRequest {
        // 今日一句、日记、主动消息都是轻任务，用低强度省额度
        RelayRequest(engine: persona.engine.rawValue, model: PromptBuilder.model(for: persona), effort: "low",
                     system: PromptBuilder.system(for: persona, convo: nil, members: [persona]), prompt: prompt)
    }

    static func todayTodos(_ context: ModelContext) -> [TodoItem] {
        let end = Date.now.startOfDay.adding(days: 1)
        let all = (try? context.fetch(FetchDescriptor<TodoItem>(predicate: #Predicate { !$0.isDone }))) ?? []
        return all.filter { ($0.dueDate ?? .distantPast) < end }.sorted(by: TodoItem.order)
    }

    static func todosDone(on day: Date, context: ModelContext) -> [TodoItem] {
        let start = day.startOfDay, end = start.adding(days: 1)
        let all = (try? context.fetch(FetchDescriptor<TodoItem>(predicate: #Predicate { $0.isDone }))) ?? []
        return all.filter { ($0.completedAt ?? .distantPast) >= start && ($0.completedAt ?? .distantPast) < end }
    }

    static func messagesOn(_ day: Date, context: ModelContext) -> [Message] {
        let start = day.startOfDay, end = start.adding(days: 1)
        let all = (try? context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.createdAt >= start && $0.createdAt < end }))) ?? []
        return all.filter { $0.status == .done && !$0.content.isEmpty || $0.kind != .text }
            .sorted { $0.createdAt < $1.createdAt }
    }
}
