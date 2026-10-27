import Foundation
import Observation
import SwiftData

/// 正在写哪几天的日记：待办页据此显示「正在写…」
@MainActor
@Observable
final class DiaryState {
    static let shared = DiaryState()
    var writing: Set<Date> = []
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
        await proactive(context: context, relay: relay, personas: personas)
        Reminders.syncDiaryReminder()
    }

    /// 日记由你在待办页选的那位角色来写，没选就是第一位。待办页打开时、以及 App 开着时每隔一会儿都会检查一次
    static func writeDiaries(context: ModelContext, relay: RelayClient) async {
        guard !DemoMode.isOn, relay.isConnected else { return }
        let personas = context.allPersonas()
        let writerID = UserDefaults.standard.string(forKey: Prefs.diaryWriter).flatMap(UUID.init(uuidString:))
        guard let writer = personas.first(where: { $0.id == writerID }) ?? personas.first else { return }
        await diaries(context: context, relay: relay, persona: writer)
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
        guard let text = try? await relay.complete(request(persona, prompt)), !text.isEmpty else { return }
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
            guard messages.count >= 3 else { continue }
            let names = Dictionary(context.allPersonas().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            let done = todosDone(on: day, context: context).map(\.title).joined(separator: "、")
            let prompt = """
            下面是 \(Fmt.md.string(from: day)) 你和\(PromptBuilder.userName)的聊天：

            \(PromptBuilder.transcript(Array(messages.suffix(80)), names: names))

            \(done.isEmpty ? "" : "这天完成的待办：\(done)。\n")
            请以「\(persona.name)」的第一人称写这一天的日记，150 字左右，温柔真诚，写你们一起聊过的事和你的感受，不要列清单。
            最后另起一行，只写：心情：两个字
            """
            DiaryState.shared.writing.insert(day)
            defer { DiaryState.shared.writing.remove(day) }
            guard let raw = try? await relay.complete(request(persona, prompt)), !raw.isEmpty else { continue }
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
        for persona in personas where persona.proactive {
            let convo = context.chat(for: persona)
            let planned = (convo.messages ?? []).contains { $0.isProactive && $0.createdAt > now }
            guard !planned else { continue }
            let deliver = nextSlot(after: now, frequency: persona.proactiveFreq)
            let history = convo.visibleMessages(at: now)
            let names = [persona.id: persona.name]
            let todos = todayTodos(context).map(\.title).prefix(5).joined(separator: "、")
            let memory = convo.memory.trimmed
            let prompt = """
            \(memory.isEmpty ? "" : "你记得的关于\(PromptBuilder.userName)的事：\n\(memory)\n\n")下面是你们最近的聊天记录：

            \(history.isEmpty ? "（还没有聊过）" : PromptBuilder.transcript(Array(history.suffix(20)), names: names))

            现在是 \(Fmt.full.string(from: now))。你打算在 \(Fmt.full.string(from: deliver)) 主动给\(PromptBuilder.userName)发一条消息。\(todos.isEmpty ? "" : "TA 最近的待办有：\(todos)。")
            像朋友一样自然地开个话题：可以接着之前聊的事、关心一下 TA、或者轻轻提醒一件事。一两句话，口语化，不要说「我来主动找你」。只输出消息内容。
            """
            guard let text = try? await relay.complete(request(persona, prompt)), !text.isEmpty else { continue }
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

    /// 根据频率挑一个合适的时间，避开免打扰和深夜
    static func nextSlot(after now: Date, frequency: Int) -> Date {
        let hours: ClosedRange<Double> = switch frequency {
        case 0: 26...44
        case 2: 3...6
        default: 10...20
        }
        var date = now.addingTimeInterval(Double.random(in: hours) * 3600)
        let cal = Calendar.current
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
        let now = Date.now
        for m in convo.messages ?? [] where m.isProactive && m.createdAt > now {
            Reminders.cancelProactive(messageID: m.id)
            context.delete(m)
        }
    }

    // MARK: - 工具

    private static func request(_ persona: Persona, _ prompt: String) -> RelayRequest {
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
