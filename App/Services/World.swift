import Foundation
import SwiftData

/// 世界观：大家生活的世界、你是谁、彼此的关系、每个角色自己的生活（作息、今天的安排、心情）、世界里发生的事。
/// 都存在本机一个小文件里（不改数据库）。每天第一次连上电脑时，用一次请求给所有人安排好今天（见 dailyTurn）。
/// 聊天页不显示这些，只是让 TA 的言行对得上：睡着了晚点回、忙的时候说「刚在采访」、聊起世界里刚发生的事
enum World {
    // MARK: - 存的东西

    struct Relation: Codable, Identifiable, Hashable {
        var id = UUID()
        /// 两个人：角色 ID，nil 是你
        var a: UUID?
        var b: UUID?
        var text: String
    }

    struct Rhythm: Codable, Hashable {
        /// 几点睡、几点起、几点到几点在忙（小时，可以带半点，比如 1.0、8.5）
        var sleep: Double = 1
        var wake: Double = 8.5
        var busyFrom: Double = 10
        var busyTo: Double = 18
        /// 周末不忙
        var weekendFree = true
    }

    struct PlanItem: Codable, Hashable {
        /// 几点（小时，带小数）
        var at: Double
        var what: String
    }

    struct Life: Codable, Hashable {
        /// 职业、住在哪
        var role = ""
        var rhythm = Rhythm()
        /// 真实作息：按上面的时间睡觉、忙
        var realRhythm = true
        /// 今天的安排（哪一天的）
        var planDay: Date?
        var plan: [PlanItem] = []
        var mood = ""
    }

    struct Event: Codable, Identifiable, Hashable {
        var id = UUID()
        var day: Date
        var text: String
        /// 牵涉到谁（角色 ID）
        var who: [UUID] = []
    }

    struct State: Codable, Equatable {
        var world = ""
        var you = ""
        /// 世界里大家在哪个城市（填了就按这个城市的天气过日子）
        var city = ""
        var relations: [Relation] = []
        var lives: [UUID: Life] = [:]
        var events: [Event] = []
        /// Living 里的几个开关
        var lifeOn = true
        var moodCarry = true
        var eventsOn = true
        /// 上次给大家安排今天是哪一天
        var lastTurn: Date?
    }

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("world.json")
    }

    nonisolated(unsafe) private static var cache: State?

    static var state: State {
        get {
            if let cache { return cache }
            let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
            cache = loaded
            return loaded
        }
        set {
            cache = newValue
            if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: url, options: .atomic) }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static let changed = Notification.Name("world.changed")

    /// 恢复出厂设置时清掉
    static func clear() {
        try? FileManager.default.removeItem(at: url)
        cache = State()
    }

    static func life(_ id: UUID) -> Life { state.lives[id] ?? Life() }

    static func setLife(_ life: Life, for id: UUID) {
        var s = state
        s.lives[id] = life
        state = s
    }

    // MARK: - 此刻

    /// 现在是几点（小时，带小数）
    static func hour(_ date: Date = .now) -> Double {
        let cal = Calendar.current
        return Double(cal.component(.hour, from: date)) + Double(cal.component(.minute, from: date)) / 60
    }

    /// 某个时刻落在不在「从 a 到 b」里（可以跨过半夜，比如 1 点睡到 8 点半、23 点睡到 7 点）
    static func within(_ t: Double, from a: Double, to b: Double) -> Bool {
        a <= b ? (t >= a && t < b) : (t >= a || t < b)
    }

    enum Status { case asleep, busy, free }

    /// TA 这会儿在干嘛：按 TA 的作息
    static func status(of id: UUID, at date: Date = .now) -> Status {
        let s = state
        guard s.lifeOn else { return .free }
        let life = life(id)
        guard life.realRhythm else { return .free }
        let t = hour(date)
        if within(t, from: life.rhythm.sleep, to: life.rhythm.wake) { return .asleep }
        let weekend = Calendar.current.isDateInWeekend(date)
        if !(weekend && life.rhythm.weekendFree), within(t, from: life.rhythm.busyFrom, to: life.rhythm.busyTo) { return .busy }
        return .free
    }

    /// 今天安排里，现在正在做的那件
    static func current(of id: UUID, at date: Date = .now) -> PlanItem? {
        let life = life(id)
        guard let day = life.planDay, Calendar.current.isDate(day, inSameDayAs: date) else { return nil }
        let t = hour(date)
        return life.plan.last { $0.at <= t }
    }

    /// TA 早上几点醒（下一次）
    static func nextWake(of id: UUID, after date: Date = .now) -> Date {
        let w = life(id).rhythm.wake
        let cal = Calendar.current
        let base = cal.startOfDay(for: date).addingTimeInterval(w * 3600)
        return base > date ? base : base.addingTimeInterval(86400)
    }

    // MARK: - 写进提示词

    /// 一整天都不变的部分（世界、你、关系、TA 自己是谁、作息）
    static func systemNotes(for persona: Persona, members: [Persona]) -> String? {
        let s = state
        var lines: [String] = []
        if !s.world.trimmed.isEmpty { lines.append("你们生活的世界：\(s.world.trimmed)") }
        if !s.you.trimmed.isEmpty { lines.append("\(PromptBuilder.userName)在这个世界里：\(s.you.trimmed)") }
        let life = life(persona.id)
        if !life.role.trimmed.isEmpty { lines.append("你在这个世界里：\(life.role.trimmed)") }
        if s.lifeOn, life.realRhythm {
            let r = life.rhythm
            lines.append("你有自己的作息：大概 \(clock(r.sleep)) 睡、\(clock(r.wake)) 起，\(clock(r.busyFrom))～\(clock(r.busyTo)) 在忙\(r.weekendFree ? "（周末不忙）" : "")。")
        }
        let names = nameMap(members)
        let mine = s.relations.filter { $0.a == persona.id || $0.b == persona.id || $0.a == nil || $0.b == nil }
        if !mine.isEmpty {
            lines.append("大家之间的关系：" + mine.map { "\(name($0.a, names))和\(name($0.b, names))：\($0.text)" }.joined(separator: "；") + "。")
        }
        guard !lines.isEmpty else { return nil }
        if s.lifeOn { lines.append("你有自己的生活：聊天时可以自然地说起你今天在做的事、世界里刚发生的事，但别每句都提。") }
        return lines.joined(separator: "\n")
    }

    /// 这一刻的部分：现在在做什么、今天接下来、最近世界里的事、心情
    static func momentNotes(for persona: Persona) -> String {
        let s = state
        guard s.lifeOn else { return "" }
        var parts: [String] = []
        let life = life(persona.id)
        if let now = current(of: persona.id) { parts.append("你现在在：\(now.what)。") }
        if let day = life.planDay, Calendar.current.isDateInToday(day) {
            let t = hour()
            let next = life.plan.filter { $0.at > t }.prefix(3).map { "\(clock($0.at)) \($0.what)" }
            if !next.isEmpty { parts.append("你今天接下来：\(next.joined(separator: "；"))。") }
            if s.moodCarry, !life.mood.isEmpty { parts.append("你今天的心情：\(life.mood)。") }
        }
        if s.eventsOn {
            let recent = s.events.filter { Date.now.timeIntervalSince($0.day) < 4 * 86400 }.suffix(4)
            if !recent.isEmpty { parts.append("最近世界里发生的事：" + recent.map(\.text).joined(separator: "；") + "。") }
        }
        return parts.joined()
    }

    static func clock(_ h: Double) -> String {
        let total = Int((h * 60).rounded()) % (24 * 60)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func nameMap(_ members: [Persona]) -> [UUID: String] {
        Dictionary(members.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    private static func name(_ id: UUID?, _ names: [UUID: String]) -> String {
        id.map { names[$0] ?? "TA" } ?? PromptBuilder.userName
    }

    // MARK: - 每天给大家安排今天

    private nonisolated(unsafe) static var turning = false

    /// 每天第一次连上电脑时：一次请求，给每个角色排好今天的安排和心情，再写一两件世界里发生的事
    @MainActor
    static func dailyTurn(context: ModelContext, relay: RelayClient) async {
        var s = state
        guard s.lifeOn, !turning, !DemoMode.isOn, relay.isConnected else { return }
        let today = Date.now.startOfDay
        guard s.lastTurn.map({ !Calendar.current.isDate($0, inSameDayAs: today) }) ?? true else { return }
        let personas = context.allPersonas().filter { !$0.canWork }
        guard let writer = personas.first else { return }
        turning = true
        defer { turning = false }
        let names = nameMap(personas)
        let people = personas.map { p -> String in
            let l = life(p.id)
            return "- \(p.name)：\(l.role.isEmpty ? p.bio : l.role)；作息 \(clock(l.rhythm.sleep)) 睡 \(clock(l.rhythm.wake)) 起，\(clock(l.rhythm.busyFrom))～\(clock(l.rhythm.busyTo)) 忙"
        }.joined(separator: "\n")
        let relations = s.relations.map { "\(name($0.a, names))和\(name($0.b, names))：\($0.text)" }.joined(separator: "；")
        let recent = s.events.suffix(6).map { "\(Fmt.md.string(from: $0.day))：\($0.text)" }.joined(separator: "\n")
        let weather = Weather.summary ?? ""
        let prompt = """
        你在帮一个温柔的小世界安排今天。
        世界：\(s.world.isEmpty ? "现代都市，大家都是普通人。" : s.world)
        \(PromptBuilder.userName)：\(s.you.isEmpty ? "（没有写）" : s.you)
        人物：
        \(people)
        关系：\(relations.isEmpty ? "（没有写）" : relations)
        最近发生的事：
        \(recent.isEmpty ? "（还没有）" : recent)
        今天：\(Fmt.day.string(from: .now))。\(weather)

        给每个人物安排今天：4～6 件事，按时间先后，符合 TA 的身份和作息，平平常常、有生活气，偶尔有点小起伏；再给一个两个字的心情。
        再写 0～2 件今天世界里发生的、大家都会知道的小事（可以是两个人物之间的，也可以和\(PromptBuilder.userName)有关），没有就不写。
        只输出 JSON，不要别的字：{"people":[{"name":"名字","mood":"两个字","plan":[{"time":"09:30","what":"做什么"}]}],"events":[{"text":"发生了什么","who":["名字"]}]}
        """
        guard let raw = try? await relay.complete(Companion.lightRequest(writer, prompt)),
              let json = raw.firstIndex(of: "{").flatMap({ start in raw.lastIndex(of: "}").map { String(raw[start...$0]) } }),
              let data = json.data(using: .utf8),
              let turn = try? JSONDecoder().decode(Turn.self, from: data) else { return }
        s = state
        for p in turn.people {
            guard let persona = personas.first(where: { $0.name == p.name }) else { continue }
            var l = s.lives[persona.id] ?? Life()
            l.planDay = today
            l.plan = p.plan.compactMap { item in hourValue(item.time).map { PlanItem(at: $0, what: item.what) } }.sorted { $0.at < $1.at }
            l.mood = String(p.mood.prefix(4))
            s.lives[persona.id] = l
        }
        if s.eventsOn {
            for e in turn.events ?? [] where !e.text.trimmed.isEmpty {
                let who = (e.who ?? []).compactMap { n in personas.first { $0.name == n }?.id }
                s.events.append(Event(day: today, text: e.text.trimmed, who: who))
            }
            s.events = Array(s.events.suffix(60))
        }
        s.lastTurn = today
        state = s
    }

    private struct Turn: Decodable {
        struct Person: Decodable {
            struct Item: Decodable { var time: String; var what: String }
            var name: String
            var mood: String
            var plan: [Item]
        }
        struct Happening: Decodable { var text: String; var who: [String]? }
        var people: [Person]
        var events: [Happening]?
    }

    /// 「09:30」→ 9.5
    static func hourValue(_ s: String) -> Double? {
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == "：" }).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard let h = parts.first, (0..<24).contains(h) else { return nil }
        return h + (parts.count > 1 ? min(59, parts[1]) / 60 : 0)
    }

    // MARK: - 快到的日子

    struct Coming: Hashable {
        var day: Date
        var what: String
        var sub: String
    }

    /// 接下来两周：你们的纪念日（认识满 100 天、整年）、节日
    static func comingUp(personas: [Persona], from now: Date = .now) -> [Coming] {
        let cal = Calendar.current
        let start = now.startOfDay, end = start.adding(days: 14)
        var list: [Coming] = []
        for p in personas {
            let first = p.createdAt.startOfDay
            for mark in [100, 200, 300, 365, 500, 730, 1000, 1095] {
                let d = first.adding(days: mark - 1)
                if d >= start && d < end { list.append(Coming(day: d, what: "和\(p.name)认识 \(mark) 天", sub: String(localized: "纪念日"))) }
            }
        }
        let year = cal.component(.year, from: now)
        let holidays: [(Int, Int, String)] = [(1, 1, "元旦"), (2, 14, "情人节"), (3, 8, "妇女节"), (5, 1, "劳动节"), (5, 20, "520"),
                                              (6, 1, "儿童节"), (10, 1, "国庆节"), (10, 31, "万圣节"), (11, 11, "双十一"),
                                              (12, 24, "平安夜"), (12, 25, "圣诞节"), (12, 31, "跨年夜")]
        for y in [year, year + 1] {
            for (m, d, name) in holidays {
                if let date = cal.date(from: DateComponents(year: y, month: m, day: d)), date >= start, date < end {
                    list.append(Coming(day: date, what: name, sub: String(localized: "节日")))
                }
            }
        }
        return list.sorted { $0.day < $1.day }
    }
}
