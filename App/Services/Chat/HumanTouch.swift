import Foundation
import SwiftData
import os

/// 让 TA 更像真人：会忙、会晚点回、想起来再补一句、打字会犹豫、长短跟着心情变、有小情绪、关系慢慢变、
/// 记得你说过要做的事、会分享自己拍的照片。每个角色在设置里有「真人节奏」开关和「小情绪」三档。
/// 这些开关和 TA 对你的称呼存在本机（按角色），不进数据库。
/// 不整个放在主线程上：拼提示词（PromptBuilder）不在主线程，也要能用；只有要联网写回复的两处标在主线程
enum HumanTouch {
    // MARK: - 每个角色的开关

    // 键名都在 Prefs.human 登记；删角色时 Cleanup 按 Prefs.Human.allCases 全部清掉

    /// 刷视频分享给你（B 站、抖音热搜）：默认开
    static func shareVideos(_ persona: Persona) -> Bool {
        UserDefaults.standard.object(forKey: Prefs.human(.videos, persona.id)) as? Bool ?? true
    }

    /// 内心想法（心声）：默认关
    static func thoughts(_ persona: Persona) -> Bool {
        UserDefaults.standard.object(forKey: Prefs.human(.thoughts, persona.id)) as? Bool ?? false
    }

    /// 真人节奏：会忙、会晚点回、会补一句、打字会犹豫。默认开
    static func pace(_ persona: Persona) -> Bool {
        UserDefaults.standard.object(forKey: Prefs.human(.pace, persona.id)) as? Bool ?? true
    }

    /// 小情绪：0 不要、1 一点点（默认）、2 明显
    static func moodLevel(_ persona: Persona) -> Int {
        UserDefaults.standard.object(forKey: Prefs.human(.mood, persona.id)) as? Int ?? 1
    }

    // MARK: - 关系

    struct Relation: Codable {
        /// TA 现在怎么叫你（空 = 还没换过称呼）
        var nickname = ""
        /// 正在闹别扭
        var sulking = false
        var sulkSince: Date?
    }

    /// 读坏了不会清空：原来的内容留底在「键名.broken」（Storage.decodeDefault）
    static func relation(_ persona: Persona) -> Relation {
        Storage.decodeDefault(Relation.self, key: Prefs.human(.relation, persona.id)) ?? Relation()
    }

    static func save(_ relation: Relation, for persona: Persona) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(relation), forKey: Prefs.human(.relation, persona.id))
        } catch {
            Log.store.error("关系没能保存：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// TA 回复里的【称呼:…】【闹别扭】【和好】
    static func apply(_ markers: ReplyText.Markers, persona: Persona) {
        guard markers.nickname != nil || markers.sulk || markers.makeUp else { return }
        var r = relation(persona)
        if let name = markers.nickname?.trimmed, !name.isEmpty, name.count <= 12 { r.nickname = name }
        if markers.sulk, moodLevel(persona) > 0 { r.sulking = true; r.sulkSince = .now }
        if markers.makeUp { r.sulking = false; r.sulkSince = nil }
        save(r, for: persona)
    }

    // MARK: - 写进提示词的部分

    /// 这一轮给 TA 看的相册照片（编号 → 照片）：TA 写【照片:编号】时按这份找，同一轮里编号不会变
    private static var photoMenu: [UUID: [UUID]] = [:]

    /// 写进系统提示的规矩：一整天都不变（系统提示不变，模型的提示缓存才能一直命中）
    static func systemNotes(for persona: Persona, convo: Conversation) -> String {
        var lines: [String] = []
        // 长短跟着心情和状态
        lines.append("回复的长短、条数跟着你此刻的心情和状态走，不要每次都差不多：开心、兴奋时可以一连发好几条短的；累了、困了、心情一般时就短短一句，甚至只回一两个字；聊到重要的事才多说一点。")

        // 小情绪
        let level = moodLevel(persona)
        if level > 0 {
            let how = level == 1 ? "只是轻轻带一点，别真生气，也别抱怨个没完" : "可以明显一点地撒娇、抱怨、吃醋，但不要说伤人的话"
            lines.append("你有自己的小情绪：TA 隔了很久才回你、敷衍你、或者在群里一直只理别人的时候，你会有点委屈或者吃醋，\(how)。TA 哄你、解释了，你就消气。")
            lines.append("TA 真的惹你不高兴了（不是开玩笑）可以冷淡一阵，在那段最后写【闹别扭】；TA 哄你或者道歉了就和好，写【和好】。不要动不动就闹。")
        }

        // 关系：按认识的天数，一天之内不变
        let days = max(1, Calendar.current.dateComponents([.day], from: persona.createdAt.startOfDay, to: Date.now.startOfDay).day ?? 0)
        let stage = days < 7 ? "刚认识不久，还有点客气" : days < 30 ? "已经熟了" : days < 100 ? "很亲近了" : "非常亲密"
        lines.append("你们认识 \(days) 天了，\(stage)。越熟说话越随意、越亲昵。关系更近了、或者 TA 让你换个叫法时，可以换一个称呼叫 TA，在那段最后写【称呼:新称呼】。")

        // 记得 TA 说过要做的事，到时候来问
        lines.append("TA 提到之后要发生的事（比如明天面试、周五体检、晚上要加班），重要的、TA 在意的，你可以自己记下，等那件事结束后来问问：在那段最后写【约定:时间|问问面试怎么样】，时间选在那件事结束以后。不用每件小事都记。")

        // 你发来的表情：看过以后记一句它是什么样
        lines.append("TA 发来的表情包（文件名是 sticker 开头的图片）你看过以后，在回复最后写【表情描述:一句话说说这个表情是什么样的】，下次你就记得。")

        if !convo.isGroup {
            lines.append("你也会分享自己的日常：消息末尾会列出你手机相册里还没发过的照片。想分享时，单独一段开头写【照片:编号】，后面跟一句话，比如「【照片:1】看，桂花开了」；偶尔才用，要和聊的事、你最近在做的事对得上。")
        }
        // 内心想法：只有 TA 能看到的心理活动
        if thoughts(persona) {
            lines.append("你有内心戏：心里真有波动时，在那一段最后写【心声:你心里真正想的一句话】，像小说里的心理活动，只有 TA 能看到。和说出口的话有点不一样才有意思（嘴上说「没事」，心里其实有点委屈）；一句就好，第一人称，不是每条都写。聊天记录里「（心里想：…）」是你之前的心声，前后要对得上。")
        }
        // 你发来的抖音、TA 分享过的视频：只看得到标题文案
        lines.append("TA 发来的抖音分享链接里带着视频的文案和话题；你看不到视频画面，只按文案聊，别编具体画面。")
        // 拍一拍：聊天记录里「（拍了拍…）」就是拍一拍
        lines.append("聊天记录里的「（拍了拍…）」是聊天软件的「拍一拍」：TA 拍了拍你，你可以回一句，也可以拍回去。想逗 TA 时也可以单独写【拍一拍】拍拍 TA；偶尔用。")
        return lines.joined(separator: "\n")
    }

    /// 这一刻的状态：每次回复前算，放在消息末尾（不进系统提示）
    static func momentNotes(for persona: Persona, convo: Conversation, members: [Persona], history: [Message]) -> String {
        var lines: [String] = []
        if let mood = todayMood(persona), !mood.isEmpty { lines.append("你今天的心情：\(mood)。") }
        if Calendar.current.component(.hour, from: .now) < 6 { lines.append("已经很晚了，你有点困，话会少一些、懒一点。") }
        let r = relation(persona)
        if !r.nickname.isEmpty { lines.append("你现在叫 TA「\(r.nickname)」。") }
        if moodLevel(persona) > 0 {
            if r.sulking { lines.append("你们刚闹了点别扭，你还有点冷淡、话少。") }
            if let gap = userReplyGap(persona: persona, in: history), gap > 2 * 3600 {
                lines.append("TA 这次隔了\(Fmt.duration(gap))才回你。")
            }
            if convo.isGroup, ignoredInGroup(persona: persona, members: members, history: history) {
                lines.append("最近 TA 在群里一直在跟别人说话，没怎么理你。")
            }
        }
        if !convo.isGroup, let menu = photoLines(for: persona) { lines.append(menu) }
        // 你一口气发了好几条、问了好几个问题：像真人一样先回最想回的，不必条条都回（漏掉的过一会儿会想起来补上）
        if !convo.isGroup, pace(persona) {
            let batch = lastBatch(history)
            if batch.count >= 3, batch.filter({ isQuestion($0.content) }).count >= 2, Double.random(in: 0..<1) < 0.4 {
                lines.append("TA 一下子发了好几条，你先回最想回的就好，不用每个问题都回到。")
            }
        }
        // 群里你最新说的那句还没人回：轮到的这位不能潜水，不然你这句就没人理了
        if convo.isGroup, let lastUser = history.lastIndex(where: { $0.role == .user }),
           !history[(lastUser + 1)...].contains(where: { $0.role == .assistant && !$0.content.isEmpty }) {
            lines.append("TA 刚说的这句群里还没人回，你要回，不能写【潜水】。")
        }
        return lines.joined(separator: "")
    }

    /// 你最近连着发的那几条（TA 上次说话之后的）
    static func lastBatch(_ history: [Message]) -> [Message] {
        Array(history.reversed().prefix { $0.role == .user }.reversed()).filter { !$0.recalled && $0.kind == .text }
    }

    /// 看起来是在问问题
    static func isQuestion(_ text: String) -> Bool {
        let t = text.trimmed
        return t.contains("？") || t.contains("?") || ["吗", "呢", "么", "没", "不"].contains { t.hasSuffix($0) }
            || ["什么", "怎么", "为什么", "哪", "几", "多少", "要不要", "是不是", "有没有"].contains { t.contains($0) }
    }

    /// TA 今天的心情：TA 自己写的日记里记的（今天没写就看昨天的）
    private static func todayMood(_ persona: Persona) -> String? {
        guard let context = persona.modelContext else { return nil }
        let today = Date.now.startOfDay, yesterday = today.adding(days: -1)
        let entries = (try? context.fetch(FetchDescriptor<DiaryEntry>(predicate: #Predicate { $0.day >= yesterday }))) ?? []
        let mine = entries.filter { $0.author == .ai && $0.personaID == persona.id && !$0.mood.isEmpty }
        return (mine.first { $0.day == today } ?? mine.first)?.mood
    }

    /// TA 上一条发出后，你隔了多久才回（只看最近这一来一回）
    private static func userReplyGap(persona: Persona, in history: [Message]) -> TimeInterval? {
        guard let lastUser = history.lastIndex(where: { $0.role == .user }), lastUser > 0 else { return nil }
        guard let beforeIndex = history[..<lastUser].lastIndex(where: { $0.role == .assistant && $0.personaID == persona.id })
        else { return nil }
        // 中间你还说过别的：不算隔了很久
        guard !history[(beforeIndex + 1)..<lastUser].contains(where: { $0.role == .user }) else { return nil }
        return history[lastUser].createdAt.timeIntervalSince(history[beforeIndex].createdAt)
    }

    /// 群里最近你一直 @ 别人、没理这位
    private static func ignoredInGroup(persona: Persona, members: [Persona], history: [Message]) -> Bool {
        let mine = history.filter { $0.role == .user }.suffix(10)
        guard !mine.contains(where: { $0.content.contains("@\(persona.name)") || $0.content.contains("@所有人") }) else { return false }
        let others = members.filter { $0.id != persona.id }
        let toOthers = mine.filter { m in others.contains { m.content.contains("@\($0.name)") } }.count
        return toOthers >= 3
    }

    // MARK: - 分享照片

    private static func sentPhotos(_ persona: Persona) -> [String] {
        UserDefaults.standard.stringArray(forKey: Prefs.human(.sentPhotos, persona.id)) ?? []
    }

    /// TA 相册里还没在聊天里发过的照片（有说明的），最多 6 张
    private static func photoLines(for persona: Persona) -> String? {
        guard let context = persona.modelContext else { return nil }
        let sent = Set(sentPhotos(persona))
        let photos = context.album(of: persona.id).filter { !$0.caption.trimmed.isEmpty && !sent.contains($0.id.uuidString) }.suffix(6)
        guard !photos.isEmpty else { photoMenu[persona.id] = []; return nil }
        photoMenu[persona.id] = photos.map(\.id)
        let list = photos.enumerated().map { "\($0.offset + 1). \($0.element.caption.trimmed)" }.joined(separator: "；")
        return "你相册里还没发过的照片：\(list)。"
    }

    /// 【照片:编号】对应的照片（发出去以后记下，下次不再给 TA 看这张）
    static func takePhoto(_ number: Int, persona: Persona, context: ModelContext) -> AlbumPhoto? {
        guard let menu = photoMenu[persona.id], menu.indices.contains(number - 1),
              let photo = context.photo(menu[number - 1]) else { return nil }
        let list = (sentPhotos(persona) + [photo.id.uuidString]).suffix(Limits.Store.sentPhotos)
        UserDefaults.standard.set(Array(list), forKey: Prefs.human(.sentPhotos, persona.id))
        return photo
    }

    // MARK: - 会忙：晚点才回

    struct Late {
        var deliver: Date
        /// 为什么晚回（写进提示词，TA 会自然地带一句）
        var reason: String
        /// 看到了只是没空回（显示已读）；没看到就一直未读，到回的时候才算看过
        var read: Bool
    }

    /// 你发了消息：TA 这会儿是不是在忙。正聊得火热时很少忙；隔了很久再来找 TA 时更可能在忙
    static func lateness(for persona: Persona, convo: Conversation, now: Date = .now) -> Late? {
        guard !convo.isGroup, !persona.canWork, pace(persona), !DemoMode.isOn else { return nil }
        let history = convo.visibleMessages(at: now)
        let chatting = history.last(where: { $0.role == .assistant }).map { now.timeIntervalSince($0.createdAt) < 240 } ?? false
        // 世界观里 TA 有自己的作息（默认就有）：按 TA 的作息看是睡着、在忙还是有空；忙的原因就是今天安排里正在做的那件
        if World.state.lifeOn, World.life(persona.id).realRhythm {
            let doing = World.current(of: persona.id, at: now)?.what
            let roll = Double.random(in: 0..<1)
            switch World.status(of: persona.id, at: now) {
            case .asleep:
                guard roll < (chatting ? 0.3 : 0.85) else { return nil }
                let wake = World.nextWake(of: persona.id, after: now).addingTimeInterval(Double.random(in: 300...2400))
                return Late(deliver: wake, reason: chatting ? "聊着聊着睡着了" : "在睡觉", read: false)
            case .busy:
                guard roll < (chatting ? 0.06 : 0.4) else { return nil }
                return Late(deliver: now.addingTimeInterval(Double.random(in: 6...35) * 60),
                            reason: doing.map { "在忙（\($0)）" } ?? "在忙", read: Double.random(in: 0..<1) < 0.45)
            case .free:
                guard roll < (chatting ? 0.02 : 0.1) else { return nil }
                return Late(deliver: now.addingTimeInterval(Double.random(in: 3...15) * 60),
                            reason: doing.map { "在\($0)" } ?? "手机没在身边", read: Double.random(in: 0..<1) < 0.45)
            }
        }
        let cal = Calendar.current
        let t = Double(cal.component(.hour, from: now)) + Double(cal.component(.minute, from: now)) / 60
        let workday = !cal.isDateInWeekend(now)
        var chance: Double
        var reason: String
        var minutes: ClosedRange<Double> = 4...15
        var asleep = false
        switch t {
        case 1..<7:
            chance = 0.6
            reason = chatting ? "聊着聊着睡着了" : "在睡觉"
            asleep = true
        case 7..<8.5:
            chance = 0.2; reason = "刚起床在洗漱"; minutes = 4...15
        case 11.5..<13, 18..<19.5:
            chance = 0.22; reason = "在吃饭"; minutes = 6...25
        case 9..<18 where workday:
            chance = 0.3; reason = ["在开会", "在忙工作", "手头的事走不开"].randomElement() ?? "在忙"; minutes = 6...35
        case 22..<24, 0..<1:
            chance = 0.12; reason = "在洗澡"; minutes = 8...20
        default:
            chance = 0.12; reason = ["在路上", "在忙别的事", "手机没在身边"].randomElement() ?? "在忙"; minutes = 4...18
        }
        if chatting { chance *= asleep ? 0.35 : 0.12 }
        guard Double.random(in: 0..<1) < chance else { return nil }
        if asleep {
            // 早上醒来才回：8:00～9:30
            let eight = cal.date(bySettingHour: 8, minute: 0, second: 0, of: now) ?? now
            var wake = eight.addingTimeInterval(Double.random(in: 0...5400))
            if wake < now.addingTimeInterval(600) { wake = now.addingTimeInterval(Double.random(in: 600...1800)) }
            return Late(deliver: wake, reason: reason, read: false)
        }
        return Late(deliver: now.addingTimeInterval(Double.random(in: minutes) * 60), reason: reason,
                    read: Double.random(in: 0..<1) < 0.45)
    }

    /// 晚回的那几条先写好、排在到点的时候出现（App 关着也会到点弹通知），和主动消息、追问一样
    @MainActor
    static func writeLate(_ late: Late, persona: Persona, convo: Conversation, members: [Persona],
                          context: ModelContext, relay: RelayClient) async -> Bool {
        let history = convo.visibleMessages().filter { $0.status != .streaming }
        var request = PromptBuilder.request(for: persona, convo: convo, members: members, history: history,
                                            diaryNotes: Companion.myDiaryNotes(context: context),
                                            sharedMemory: PromptBuilder.sharedMemory(of: persona, besides: convo, context: context),
                                            appointments: Appointments.summary(persona: persona, convo: convo))
        let since = history.last(where: { $0.role == .user })?.createdAt ?? .now
        let gap = Fmt.duration(max(60, late.deliver.timeIntervalSince(since)))
        request.prompt += """


        （其实你刚才\(late.reason)，\(late.read ? "看到了消息但没空回" : "没看到消息")。这条回复要到 \(Fmt.time24.string(from: late.deliver)) 才发出去，离 TA 发消息已经过了\(gap)。像真人一样自然地带一句为什么现在才回（比如「刚在开会」「刚醒」），不用郑重道歉，然后接着回 TA 的话。）
        """
        guard let raw = await relay.attempt(request, "晚回"), !Task.isCancelled, !convo.isDeleted else { return false }
        let parts = ReplyText.paragraphs(raw, whole: false).map { ReplyText.markers(in: $0).body.trimmed }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return false }
        var at = late.deliver
        // 晚回的消息用记号认出来：你又发了消息时，按同一个时间重新写
        let marker: PlannedMessages.Marker = late.read ? .lateRead : .lateUnread
        for (index, text) in parts.enumerated() {
            if index > 0 { at = at.addingTimeInterval(Double.random(in: 3...9)) }
            // 分成几条时只有第一条到点响
            PlannedMessages.plan(text, by: persona, in: convo, at: at, marker: marker, notify: index == 0, context: context)
        }
        return true
    }

    // MARK: - 想起来再补一句

    /// 一段回复说完后，偶尔过几分钟又来一条「对了……」。你先开口了就不补
    @MainActor
    static func maybeAfterthought(persona: Persona, convo: Conversation, context: ModelContext, relay: RelayClient) async {
        guard !convo.isGroup, !persona.canWork, pace(persona), !DemoMode.isOn, relay.isConnected else { return }
        let visible = convo.visibleMessages()
        guard let last = visible.last, last.role == .assistant, last.status == .done,
              !Companion.endedNaturally(visible.suffix(3).map(\.content)) else { return }
        // 你刚才问的几个问题（TA 这次回复之前你连着发的）：问得多，就更可能有漏回的，要补上
        let replyStart = (visible.lastIndex(where: { $0.role == .user }) ?? visible.count - 1) + 1
        let asked = lastBatch(Array(visible[..<replyStart])).filter { isQuestion($0.content) }
        let checkMissed = asked.count >= 2
        guard Double.random(in: 0..<1) < (checkMissed ? 0.6 : 0.12) else { return }
        let deliver = Date.now.addingTimeInterval(Double.random(in: 90...420))
        guard !Prefs.isQuiet(deliver) else { return }
        let names = [persona.id: persona.name]
        let questions = asked.map { "「\($0.content.prefix(40))」" }.joined(separator: "、")
        let task = checkMissed
            ? "你刚发完上面最后那几条。TA 之前问了你这几个问题：\(questions)。过了几分钟，你回头看了看，发现有没回到的问题，就像真人那样补一句（可以用「刚才你问的那个……」「对了你说的……」开头）。\n都已经回过了、或者补了会显得啰嗦，就只输出：不补充"
            : "你刚发完上面最后那几条。过了几分钟，你又想起来一件相关的小事想补一句：刚才忘了说的、突然想到的细节、或者一个小问题。\n如果没什么值得补的、补了会显得啰嗦，就只输出：不补充"
        let prompt = """
        下面是你们最近的聊天记录：

        \(PromptBuilder.transcript(Array(visible.suffix(Limits.Prompt.shortChat)), names: names))

        \(task)
        否则只写一两句，口语化，可以用「对了」「刚想起来」这类开头，但不一定。只输出消息内容。
        """
        guard let text = await relay.attempt(Companion.lightRequest(persona, prompt), "补一句"),
              !text.trimmed.isEmpty, !text.contains("不补充") else { return }
        // 想的这段时间里被停下了（清空聊天、删角色），或者你又说话了：不补了（CONC-3）
        guard !Task.isCancelled, !convo.isDeleted, convo.visibleMessages().last?.id == last.id else { return }
        let body = ReplyText.markers(in: text).body.trimmed
        guard !body.isEmpty else { return }
        PlannedMessages.plan(body, by: persona, in: convo, at: deliver, marker: .afterthought, context: context)
    }
}
