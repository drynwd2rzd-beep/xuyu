import Foundation
import SwiftData

/// 拼出发给模型的内容：人设和规则（system）、最近的聊天记录、附件
enum PromptBuilder {
    static var userName: String {
        let n = Prefs.nicknameValue
        return n.isEmpty ? "用户" : n
    }

    static func model(for persona: Persona) -> String {
        persona.model.isEmpty ? Prefs.defaultModel(for: persona.engine) : persona.model
    }

    static func effort(for persona: Persona) -> String {
        persona.effort.isEmpty ? Prefs.defaultEffort(for: persona.engine) : persona.effort
    }

    // MARK: - 人设和规则

    static func system(for persona: Persona, convo: Conversation?, members: [Persona], stickerCategories: [String] = []) -> String {
        var parts: [String] = []
        let base = persona.systemPrompt.trimmed
        parts.append(base.isEmpty ? "你是「\(persona.name)」。" : base)
        parts.append("""
        你在一个手机聊天 App 里和\(userName)聊天。像发消息一样自然、口语化地回复，不要长篇大论；想分几条说的时候用空行隔开，每段一两句话。只有内容复杂时才用 Markdown。不要用颜文字（比如 (≧▽≦)、^^ 这种）。
        """)
        if let convo, convo.isGroup {
            let others = members.filter { $0.id != persona.id }.map(\.name)
            let roster = (["\(userName)（用户）"] + others).joined(separator: "、")
            parts.append("""
            你正在群聊「\(convo.displayTitle(members))」里，你的名字是「\(persona.name)」。群成员：\(roster)。
            只以「\(persona.name)」的身份说话，不要替别人发言，不要在开头写自己的名字。
            """)
        }
        if !stickerCategories.isEmpty {
            parts.append("""
            想发表情包时，单独一段只写【表情:分类名】，可以用的分类只有这些：\(stickerCategories.joined(separator: "、"))。偶尔用一下就好，不要每次都发；没有合适的分类就不发，也不要用文字描述或假装发表情。
            """)
        }
        if convo != nil {
            parts.append("""
            想针对\(userName)之前说的某句话回应时，可以在那一段开头写【引用:那句话里的几个字】，像聊天软件里的引用回复；偶尔用。
            \(userName)让你到某个时间来找 TA、提醒 TA 做什么（比如「晚上找我」「半小时后提醒我」「八点催我睡觉」「每天 22:30 叫我睡觉」），答应的同时在回复末尾单独写一个【约定:时间|事情】，到点 App 会让你真的发消息过去。时间只能写成：21:30（今天，已经过了就是明天）、明天 08:00、+30分钟、+2小时，每天都要就在前面加「每天」，比如【约定:每天 22:30|催睡觉】。「晚上」「待会儿」这种没说具体时间的，你挑一个合适的钟点。TA 说不用了、取消了，就写【取消约定:事情】。这些标记 TA 看不到，不要在话里提到它们。
            """)
        }
        if let memory = convo?.memory.trimmed, !memory.isEmpty {
            parts.append("你记得的关于\(userName)、以及你们之间的事（来自更早的聊天）：\n\(memory)")
        }
        // 这里只写到「今天」：一整天内开头都不变，模型的提示缓存才能一直命中；具体时间放在消息末尾
        parts.append("今天是 \(Fmt.day.string(from: .now))。")
        return parts.joined(separator: "\n\n")
    }

    /// TA 能发的表情分类：你的图片表情包
    static func stickerCategories(context: ModelContext) -> [String] {
        let stickers = (try? context.fetch(FetchDescriptor<Sticker>())) ?? []
        var names: [String] = []
        for s in stickers where !names.contains(s.pack) { names.append(s.pack) }
        return names
    }

    // MARK: - 聊天记录

    /// 还没总结进记忆、要逐条发给模型的那部分聊天
    static func recent(_ history: [Message], convo: Conversation) -> [Message] {
        Array(history.filter { $0.createdAt > convo.memoryUntil }.suffix(Memory.maxWindow))
    }

    static func line(for m: Message, names: [UUID: String]) -> String {
        let who = m.role == .user ? userName : (m.personaID.flatMap { names[$0] } ?? "AI")
        var body: String
        switch m.kind {
        case .text: body = m.content
        case .images: body = "[发了 \(m.attachments?.count ?? 0) 张图片]" + (m.content.isEmpty ? "" : " \(m.content)")
        case .file: body = "[发了文件：\(m.sortedAttachments.map(\.fileName).joined(separator: "、"))]" + (m.content.isEmpty ? "" : " \(m.content)")
        case .note: body = "【写下的想法】\(m.content)"
        case .sticker: body = "[发了一个表情]"
        }
        if !m.quote.isEmpty { body = "（引用「\(m.quote)」）" + body }
        if m.recalled { body = "（撤回了一条消息）" }
        return "[\(Fmt.time24.string(from: m.createdAt))] \(who)：\(body)"
    }

    static func transcript(_ messages: [Message], names: [UUID: String]) -> String {
        var lines: [String] = []
        var lastDay: Date?
        for m in messages where m.status != .error {
            let day = m.createdAt.startOfDay
            if day != lastDay {
                lines.append("— \(Fmt.md.string(from: m.createdAt)) —")
                lastDay = day
            }
            lines.append(line(for: m, names: names))
        }
        return lines.joined(separator: "\n")
    }

    /// 感知聊天间隔：隔了 12 小时以上心里有数；隔了 3 天以上自然地表现出好久没聊了。
    /// 你连着发了几条时，从这几条的第一条往前算
    static func gapNote(_ history: [Message]) -> String {
        let visible = history.filter { $0.status != .error && !$0.recalled }
        let streak = visible.reversed().prefix { $0.role == .user }
        guard let first = streak.last,
              let previous = visible.last(where: { $0.role != .user && $0.createdAt < first.createdAt }) else { return "" }
        let gap = first.createdAt.timeIntervalSince(previous.createdAt)
        if gap >= 3 * 86400 { return "（距离你们上一次聊天已经过去了\(Fmt.duration(gap))，可以自然地表现出好久没聊了。）" }
        if gap >= 12 * 3600 { return "（上一次聊天是\(Fmt.duration(gap))前，心里知道就好，不用特意提，自然地接着聊。）" }
        return ""
    }

    /// 记忆打通：在群里也记得你们私聊的事，私聊时也记得群里聊过的事
    static func sharedMemory(of persona: Persona, besides convo: Conversation, context: ModelContext) -> String {
        let all = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        let others = all.filter { $0.id != convo.id && $0.memberIDs.contains(persona.id) }
        let personas = context.allPersonas()
        let names = Dictionary(personas.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let since = Date.now.addingTimeInterval(-24 * 3600)
        var parts: [String] = []
        for c in others.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(3) {
            let members = c.memberIDs.compactMap { id in personas.first { $0.id == id } }
            let place = c.isGroup ? "在群聊「\(c.displayTitle(members))」里" : "你和\(userName)私下聊天时"
            var block: [String] = []
            let memory = c.memory.trimmed
            if !memory.isEmpty {
                block.append("\(place)记得的事：\n" + (memory.count > 500 ? String(memory.prefix(500)) + "…" : memory))
            }
            // 最近一天在那边聊的几句：让刚说过的事（比如「我去群里说一声」）在这边也接得上
            let recent = c.visibleMessages().filter { $0.createdAt >= since && $0.status == .done && !$0.recalled }.suffix(8)
            if !recent.isEmpty {
                let note = c.isGroup
                    ? "\(place)最近在聊："
                    : "\(place)最近说的话（只有你们俩知道；在群里别主动说出来，除非 TA 自己先提）："
                block.append(note + "\n" + transcript(Array(recent), names: names))
            }
            if !block.isEmpty { parts.append(block.joined(separator: "\n")) }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - 一次回复的请求

    static func request(for persona: Persona, convo: Conversation, members: [Persona], history: [Message],
                        discussing: Bool = false, diaryNotes: String = "", sharedMemory: String = "",
                        stickerCategories: [String] = [], appointments: String = "") -> RelayRequest {
        let names = Dictionary(members.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let shared = (sharedMemory.isEmpty ? "" : "\(sharedMemory)\n\n")
            + (appointments.isEmpty ? "" : "你和\(userName)现在的约定：\n\(appointments)\n\n")
        let ask = discussing
            ? "大家正在讨论，请以「\(persona.name)」的身份接着说：可以回应其他人的观点、补充或提出不同看法，不要重复别人说过的。"
            : "请以「\(persona.name)」的身份回复。"
        // 你最近写的日记：TA 会记在心上，合适的时候自然地关心，但不要生硬地复述
        let diary = diaryNotes.isEmpty ? "" : "\(userName)最近几天写的日记（记在心上，合适时自然地关心，不要生硬复述）：\n\(diaryNotes)\n\n"
        let prompt = """
        \(shared)\(diary)下面是你们最近的聊天记录：

        \(transcript(recent(history, convo: convo), names: names))

        现在是 \(Fmt.time24.string(from: .now))。\(gapNote(history))\(ask)直接输出要说的话，不要加名字或时间。
        """
        return RelayRequest(engine: persona.engine.rawValue, model: model(for: persona), effort: effort(for: persona),
                            system: system(for: persona, convo: convo, members: members,
                                           stickerCategories: persona.canWork ? [] : stickerCategories),
                            prompt: prompt, attachments: newAttachments(for: persona, in: history), work: persona.canWork)
    }

    /// 这位角色上次说话之后你发的附件（群聊里别人先回了，这位也要看到你的图）
    static func newAttachments(for persona: Persona, in history: [Message]) -> [RelayAttachment] {
        let lastSpoke = history.lastIndex { $0.role == .assistant && $0.personaID == persona.id } ?? -1
        return history.suffix(from: lastSpoke + 1).filter { $0.role == .user }.flatMap(\.sortedAttachments).map { a in
            RelayAttachment(kind: a.isImage ? "image" : "file",
                            name: a.fileName.isEmpty ? "image.jpg" : a.fileName,
                            data: a.data.base64EncodedString())
        }
    }
}
