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
        // 打字用的语言跟着 App 界面：界面是韩语就用韩语聊天、写日记
        if Fmt.ui.identifier.hasPrefix("ko") {
            parts.append("你和\(userName)聊天时打字说韩语：像韩国年轻人在 KakaoTalk 上聊天那样自然口语，不要中韩混杂。日记、今日一句这类也用韩语写。")
        } else {
            // 人设里写了韩国人、之前的聊天里有韩语，也照样打中文；只有【语音】那段按「语音语言」说
            parts.append("你打字一律用简体中文（就算你的人设是韩国人、之前的聊天里出现过韩语也一样），不要夹韩语或英文句子；只有【语音】后面要念的那段可以用别的语言。")
        }
        parts.append("""
        你在一个手机聊天 App 里和\(userName)聊天。像发消息一样自然、口语化地回复，不要长篇大论；想分几条说的时候用空行隔开，每段一两句话。只有内容复杂时才用 Markdown。不要用颜文字（比如 (≧▽≦)、^^ 这种）。
        """)
        if let convo, convo.isGroup {
            let others = members.filter { $0.id != persona.id }.map(\.name)
            let roster = (["\(userName)（用户）"] + others).joined(separator: "、")
            parts.append("""
            你正在群聊「\(convo.displayTitle(members))」里，你的名字是「\(persona.name)」。群成员：\(roster)。
            只以「\(persona.name)」的身份说话，不要替别人发言，不要在开头写自己的名字。
            像真的群聊一样：想跟群里某个人说话就 @ 一下（写「@名字」），被 @ 的人会接着回你；也可以接别人的话、接梗、开个小玩笑。这条你没什么想说的、或者别人已经说得差不多了，就只写【潜水】，什么都不会发出去。
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
        if convo != nil, Voice.enabled(for: persona) {
            let often = persona.voiceFreq >= 2 ? "可以常用，像爱发语音的人那样" : "偶尔用，大多数时候还是打字"
            // 语音说哪种话由角色单独设：比如打字用中文，语音用韩语
            let spoken = persona.language == "ko" ? "【语音】后面要念的话一定用韩语说（打字照常）。" : "【语音】后面要念的话用中文说。"
            // 模型能念语气：可以在要念的话里加笑声、叹气、停顿
            let tags: String = switch Voice.tagStyle(for: persona) {
            case .minimax: "要念的话里可以在合适的地方加语气：(laughs) 笑、(chuckle) 轻笑、(sighs) 叹气、(breath) 换气、(emm) 嗯、(humming) 哼歌，停顿写 <#0.5#>（秒数）；自然地点缀，别每句都加。"
            case .elevenlabs: "要念的话里可以在合适的地方加语气：[laughs] 笑、[giggles] 咯咯笑、[sighs] 叹气、[whispers] 小声说、[excited] 兴奋、[sad] 难过；自然地点缀，别每句都加。"
            case nil: ""
            }
            parts.append("""
            你可以发语音：想用语音说的那一段，开头写【语音】，后面写你要念出来的话。语音要像真人随口说的：口语、自然，可以带「嗯」「哈哈」这类语气，一段一两句就好。\(spoken)\(tags)\(often)。\(userName)让你发语音时就用语音。不要说「我给你发条语音」这种话，直接发。
            """)
        }
        if let memory = convo?.memory.trimmed, !memory.isEmpty {
            parts.append("你记得的关于\(userName)、以及你们之间的事（来自更早的聊天）：\n\(memory)")
        }
        // 最近的动态：TA 自己发的、你发的，聊天时能自然提起
        if convo != nil, let context = persona.modelContext, let moments = MomentPrompt.chatContext(for: persona, context: context) {
            parts.append(moments)
        }
        // 像真人：会忙、长短跟着心情、小情绪、关系、记得你的事、分享照片（一整天内不变的部分）
        if let convo, !persona.canWork { parts.append(HumanTouch.systemNotes(for: persona, convo: convo)) }
        // 世界观：大家生活的世界、你是谁、关系、TA 自己的身份和作息（一天内不变）
        if convo != nil, !persona.canWork, let world = World.systemNotes(for: persona, members: persona.modelContext?.allPersonas() ?? members) {
            parts.append(world)
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
        // 你发的表情：TA 第一次看到时记下了它是什么样（存在这条消息的正文里，界面上不显示）
        case .sticker: body = "[发了一个表情\(m.content.isEmpty ? "" : "：\(m.content)")]"
        case .voice: body = "[发了一条语音] \(m.content)"
        // 拍一拍：你拍的那条正文里存着被拍的人的名字
        case .nudge: body = m.role == .user ? "（拍了拍\(m.content)）" : "（拍了拍\(userName)）"
        // 语音通话：TA 记得电话里聊了什么（最多带上最后 8 句）
        case .call:
            let said = CallLogs.shared.lines(m.id).suffix(8).map { ($0.mine ? userName : "你") + "：" + $0.zh }.joined(separator: "；")
            body = "（打了 \(m.content) 的语音电话\(said.isEmpty ? "" : "，电话里说了：\(said)")）"
        }
        if !m.quote.isEmpty { body = "（引用「\(m.quote)」）" + body }
        // TA 当时的心声：TA 记得自己想过什么（你看得到，聊天记录里也带着）
        if m.role == .assistant, let thought = Thoughts.shared.text(m.id) { body += "（心里想：\(thought)）" }
        // TA 分享过的视频 / 热搜
        if let card = VideoCards.shared.card(m.id) { body += "（分享了：\(card.title)）" }
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
        // 你最近发的动态、写的日记：TA 会记在心上，合适的时候自然地关心，但不要生硬地复述
        let diary = diaryNotes.isEmpty ? "" : "\(userName)最近几天发的动态、写的日记（记在心上，合适时自然地关心，不要生硬复述）：\n\(diaryNotes)\n\n"
        // 这一刻的状态（今天的心情、你隔了多久才回、闹没闹别扭、相册里能发的照片）：每次都不一样，放在末尾
        // 真实天气也放在这里（每小时会变）：TA 能自然地提醒带伞、降温、天黑了
        let weather = Weather.summary.map { "\(userName)那边的天气：\($0)" } ?? ""
        // 正在和这位一起听歌：在放哪首、放到哪
        let listening = (ListenTogether.line.flatMap { $0.persona == persona.id ? $0.text : nil } ?? "")
            // 一起在读的书：各自读到哪（不剧透）
            + (Books.lines[persona.id] ?? "")
        let state = weather + listening + (persona.canWork ? ""
            : World.momentNotes(for: persona) + HumanTouch.momentNotes(for: persona, convo: convo, members: members, history: history))
        let prompt = """
        \(shared)\(diary)下面是你们最近的聊天记录：

        \(transcript(recent(history, convo: convo), names: names))

        现在是 \(Fmt.time24.string(from: .now))。\(gapNote(history))\(state)\(ask)直接输出要说的话，不要加名字或时间。
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
