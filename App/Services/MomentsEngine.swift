import SwiftUI
import SwiftData

/// 动态：TA 们提前写好、到点发出；别的角色来点赞评论；你评论了 TA 会回你。
/// 都通过电脑上的中继生成，连不上时什么也不做
@MainActor
@Observable
final class MomentsEngine {
    static let shared = MomentsEngine()

    /// 正在回你评论的那几条动态（显示「正在输入」）
    private(set) var replying: Set<UUID> = []

    func toggleLike(_ moment: Moment, context: ModelContext) {
        withAnimation(Motion.snappy) { moment.likedByMe.toggle() }
        context.persist()
    }

    /// 你评论一条动态，或者回复某条评论；被回的人过一会儿回你
    func comment(_ text: String, on moment: Moment, replyTo target: MomentComment?, context: ModelContext, relay: RelayClient) {
        let text = text.trimmed
        guard !text.isEmpty else { return }
        let mine = MomentComment(personaID: nil, text: text, replyTo: target?.personaID)
        withAnimation(Motion.bubble) { moment.add(mine, context: context) }
        context.persist()
        // 谁来回：你回复的那个人；直接评论 TA 的动态就是 TA。你在自己的动态下直接留言，没有点名谁，就不回
        guard let who = (target?.personaID ?? moment.personaID).flatMap({ context.persona($0) }) else { return }
        Task { await reply(as: who, to: mine, on: moment, context: context, relay: relay) }
    }

    private func reply(as persona: Persona, to comment: MomentComment, on moment: Moment, context: ModelContext, relay: RelayClient) async {
        withAnimation(Motion.spring) { _ = replying.insert(moment.id) }
        defer { withAnimation(Motion.spring) { _ = replying.remove(moment.id) } }
        let key = "\(moment.id.uuidString)|\(comment.id.uuidString)|\(persona.id.uuidString)"
        let prompt = MomentPrompt.reply(as: persona, to: comment, on: moment, context: context)
        // 没能回（电脑没连上、出错了）：记下来，连上以后补回（以前就这么没下文了）
        guard let raw = try? await relay.complete(Companion.lightRequest(persona, prompt)) else {
            pending.insert(key)
            return
        }
        pending.remove(key)
        let text = MomentText.clean(raw)
        guard !text.isEmpty else { return }
        // 像真人一样打几个字的时间
        try? await Task.sleep(for: .seconds(Double.random(in: 1.2...2.6)))
        withAnimation(Motion.bubble) {
            moment.add(MomentComment(personaID: persona.id, text: text, replyToMe: true), context: context)
        }
        context.persist()
    }

    /// 还欠着你的回复（「动态|评论|谁来回」），存在本机，App 关了也不丢
    private var pending: Set<String> {
        get { Set((UserDefaults.standard.string(forKey: Prefs.momentPendingReplies) ?? "").split(separator: ",").map(String.init)) }
        set { UserDefaults.standard.set(newValue.sorted().joined(separator: ","), forKey: Prefs.momentPendingReplies) }
    }

    /// 连上电脑后：把当时没能回你的评论补回（动态、评论或角色已经删了的就算了）
    func retryPending(context: ModelContext, relay: RelayClient) async {
        guard relay.isConnected else { return }
        let moments = context.allMoments()
        for key in pending {
            let ids = key.split(separator: "|").compactMap { UUID(uuidString: String($0)) }
            guard ids.count == 3, let moment = moments.first(where: { $0.id == ids[0] }),
                  let comment = moment.comments?.first(where: { $0.id == ids[1] }),
                  let persona = context.persona(ids[2]) else {
                pending.remove(key)
                continue
            }
            await reply(as: persona, to: comment, on: moment, context: context, relay: relay)
        }
    }

    /// 你发一条动态：照片存进你自己的相册；TA 们过一会儿来看
    func publish(text: String, mood: String, photos: [Data], context: ModelContext, relay: RelayClient) {
        let moment = Moment(personaID: nil, text: text.trimmed, mood: mood)
        for data in photos {
            let photo = AlbumPhoto(personaID: nil, data: data)
            context.insert(photo)
            moment.photoIDs.append(photo.id)
        }
        moment.reacted = true
        withAnimation(Motion.bubble) { context.insert(moment) }
        context.persist()
        Task { await MomentsPlanner.react(to: moment, context: context, relay: relay) }
    }

    func delete(_ moment: Moment, context: ModelContext) {
        withAnimation(Motion.spring) { context.delete(moment) }
        context.persist()
    }
}

/// 后台的动态：排好每个角色下一条动态的时间、看别人的动态、给相册照片写描述（Companion.refresh 里调用）
@MainActor
enum MomentsPlanner {
    /// 两条动态之间至少隔多久（小时）：常常 4 小时，偶尔 16 小时
    nonisolated static func minGap(_ freq: Int) -> Double { freq >= 2 ? 4 : 16 }

    static func refresh(context: ModelContext, relay: RelayClient) async {
        await captionAlbum(context: context, relay: relay)
        let personas = context.allPersonas().filter { !$0.canWork }
        let now = Date.now
        let all = context.allMoments()
        for persona in personas where persona.momentsFreq > 0 {
            let theirs = all.filter { $0.personaID == persona.id }
            // 已经写好、还没到点的：等它发出去再排下一条
            if theirs.contains(where: { $0.createdAt > now }) { continue }
            // TA 睡着的时候不发：推到醒来以后
            let deliver = World.awake(nextTime(after: now, last: theirs.first?.createdAt, freq: persona.momentsFreq), for: persona.id)
            await write(for: persona, at: deliver, context: context, relay: relay)
        }
        // 到点发出来的动态：别的角色来看一眼
        for moment in context.visibleMoments(at: now) where !moment.reacted {
            moment.reacted = true
            await react(to: moment, context: context, relay: relay)
        }
        context.persist()
    }

    /// 下一条动态的时间：按频率和你的作息挑，离上一条不能太近
    static func nextTime(after now: Date, last: Date?, freq: Int) -> Date {
        let f = freq >= 2 ? 2 : 1
        var deliver = Companion.nextSlot(after: now, frequency: f)
        if let last {
            let earliest = last.addingTimeInterval(minGap(freq) * 3600)
            if deliver < earliest { deliver = Companion.nextSlot(after: earliest, frequency: f) }
        }
        return deliver
    }

    private static func write(for persona: Persona, at deliver: Date, context: ModelContext, relay: RelayClient) async {
        let photos = context.album(of: persona.id)
        let voice = Voice.enabled(for: persona)
        let prompt = MomentPrompt.post(for: persona, at: deliver, photos: photos, voice: voice, context: context)
        guard let raw = try? await relay.complete(Companion.lightRequest(persona, prompt)),
              let post = MomentText.parse(raw) else { return }
        let moment = Moment(personaID: persona.id, text: post.text, mood: post.mood, createdAt: deliver)
        if let n = post.photo, photos.indices.contains(n - 1) { moment.photoIDs = [photos[n - 1].id] }
        if voice, let spoken = post.spoken { moment.voice = try? await Voice.speak(spoken, for: persona) }
        context.insert(moment)
        context.persist()
    }

    /// 别的角色看到这条动态：点不点赞、评论什么；发动态的人有时回一句。
    /// 你发的：每个开着动态的角色都来看，几十秒到两分钟内陆续出现；TA 们发的：挑一两个人，几分钟到半小时内出现
    static func react(to moment: Moment, context: ModelContext, relay: RelayClient) async {
        let personas = context.allPersonas().filter { !$0.canWork && $0.momentsFreq > 0 }
        let others = personas.filter { $0.id != moment.personaID && (moment.isMine || $0.momentsMutual) }
        let picks = moment.isMine ? others : Array(others.shuffled().prefix(2))
        var at = max(.now, moment.createdAt)
        var commented: [MomentComment] = []
        for persona in picks {
            let prompt = MomentPrompt.react(as: persona, to: moment, context: context)
            guard let raw = try? await relay.complete(Companion.lightRequest(persona, prompt)) else { continue }
            let reaction = MomentText.parseReaction(raw)
            if reaction.like && !moment.likedBy.contains(persona.id) { moment.likedBy.append(persona.id) }
            guard let text = reaction.comment else { continue }
            at = at.addingTimeInterval(moment.isMine ? Double.random(in: 15...90) : Double.random(in: 120...1500))
            let comment = MomentComment(personaID: persona.id, text: text, createdAt: at)
            moment.add(comment, context: context)
            commented.append(comment)
        }
        // TA 自己的动态下有人评论：有时回一句
        if let author = moment.personaID.flatMap({ context.persona($0) }), let first = commented.first, Bool.random() {
            let prompt = MomentPrompt.reply(as: author, to: first, on: moment, context: context)
            if let raw = try? await relay.complete(Companion.lightRequest(author, prompt)) {
                let text = MomentText.clean(raw)
                if !text.isEmpty {
                    let reply = MomentComment(personaID: author.id, text: text, replyTo: first.personaID,
                                              createdAt: first.createdAt.addingTimeInterval(Double.random(in: 60...900)))
                    moment.add(reply, context: context)
                }
            }
        }
        context.persist()
    }

    /// 相册里新放的照片：看一眼，写一句是什么（TA 挑配图时用）。每次最多三张，省额度
    private static func captionAlbum(context: ModelContext, relay: RelayClient) async {
        let all = (try? context.fetch(FetchDescriptor<AlbumPhoto>())) ?? []
        for photo in all.filter({ $0.caption.isEmpty && $0.personaID != nil }).prefix(3) {
            guard let id = photo.personaID, let persona = context.persona(id),
                  let small = ImageUtil.downscale(photo.data, maxSide: 768, quality: 0.7) else { continue }
            var request = Companion.lightRequest(persona, "用一句话（十个字左右）说说这张照片里是什么，只输出这句话。")
            request.attachments = [RelayAttachment(kind: "image", name: "photo.jpg", data: small.base64EncodedString())]
            if let text = try? await relay.complete(request) { photo.caption = MomentText.clean(text) }
        }
        context.persist()
    }
}

/// 发给模型的动态提示
enum MomentPrompt {
    private static func name(_ id: UUID?, context: ModelContext) -> String {
        guard let id else { return PromptBuilder.userName }
        return context.persona(id)?.name ?? "朋友"
    }

    private static func when(_ date: Date) -> String {
        "\(Fmt.md.string(from: date)) \(Fmt.time24.string(from: date))"
    }

    /// 一条动态下面的评论，一行一条
    static func thread(_ moment: Moment, context: ModelContext, viewer: UUID? = nil) -> String {
        moment.visibleComments().suffix(8).map { c in
            let who = c.personaID == viewer && viewer != nil ? "你" : name(c.personaID, context: context)
            let to = c.replyToMe ? "（回复\(PromptBuilder.userName)）" : c.replyTo.map { "（回复\(name($0, context: context))）" } ?? ""
            return "\(who)\(to)：\(c.text)"
        }.joined(separator: "\n")
    }

    static func post(for persona: Persona, at deliver: Date, photos: [AlbumPhoto], voice: Bool, context: ModelContext) -> String {
        let convo = context.chat(for: persona)
        let history = Array(convo.visibleMessages().suffix(16))
        let recent = context.visibleMoments(by: persona.id).prefix(5).map { "- \(when($0.createdAt))：\($0.text)" }
        let memory = convo.memory.trimmed
        let album = photos.enumerated().map { "\($0.offset + 1). \($0.element.caption.isEmpty ? "（一张照片）" : $0.element.caption)" }
        let lang = persona.language == "ko" ? "用韩语" : "用中文"
        return """
        \(memory.isEmpty ? "" : "你记得的关于\(PromptBuilder.userName)的事：\n\(memory)\n\n")你们最近的聊天：
        \(history.isEmpty ? "（还没有聊过）" : PromptBuilder.transcript(history, names: [persona.id: persona.name]))

        你最近发过的动态（别重复）：
        \(recent.isEmpty ? "（还没发过）" : recent.joined(separator: "\n"))

        \(album.isEmpty ? "你的相册是空的，这次不配图。" : "你的相册里有这些照片，可以挑一张配图，也可以不配：\n" + album.joined(separator: "\n"))

        现在是 \(Fmt.full.string(from: .now))。你要在 \(Fmt.full.string(from: deliver)) 发一条动态（像朋友圈），\(PromptBuilder.userName)和别的朋友都能看到。
        写你那时候在做什么、想什么、看到了什么，贴着你的人设和生活；偶尔可以含蓄地带到和\(PromptBuilder.userName)聊过的事，但不是在跟 TA 说话。一两句，口语，像真人随手发的，不要表情符号、不要话题标签。
        按下面的格式输出，不要别的：
        心情：两三个字
        动态：正文
        配图：照片编号，不配图就写 无\(voice ? "\n语音：想发成语音动态，就写要念出来的那句（\(lang)），不想就写 无" : "")
        """
    }

    static func react(as persona: Persona, to moment: Moment, context: ModelContext) -> String {
        let author = name(moment.personaID, context: context)
        let photo = moment.photoIDs.first.flatMap { context.photo($0) }.map { $0.caption.isEmpty ? "（配了一张照片）" : "（配图：\($0.caption)）" } ?? ""
        let thread = thread(moment, context: context, viewer: persona.id)
        return """
        \(author)在 \(when(moment.createdAt)) 发了一条动态：
        「\(moment.text)」\(moment.mood.isEmpty ? "" : "（心情：\(moment.mood)）")\(photo)
        \(thread.isEmpty ? "还没有人评论。" : "已有的评论：\n\(thread)")

        你刷到了这条。像朋友之间那样，你会点个喜欢吗？会评论吗？评论就一句，口语，贴着你和\(author)的关系，不要表情符号。
        按格式输出，不要别的：
        喜欢：是 或 否
        评论：评论内容，不评论就写 无
        """
    }

    static func reply(as persona: Persona, to comment: MomentComment, on moment: Moment, context: ModelContext) -> String {
        let author = moment.personaID == persona.id ? "你" : name(moment.personaID, context: context)
        let who = name(comment.personaID, context: context)
        return """
        \(author)发了一条动态：「\(moment.text)」
        下面的评论：
        \(thread(moment, context: context, viewer: persona.id))

        \(who)刚刚评论：「\(comment.text)」。回\(who)一句，口语，贴着你们的关系，不要表情符号。只输出回复的内容。
        """
    }

    /// 聊天时让 TA 知道最近的动态：TA 自己发的、你发的，还有底下的评论
    static func chatContext(for persona: Persona, context: ModelContext) -> String? {
        let since = Date.now.adding(days: -3)
        let theirs = context.visibleMoments(by: persona.id).filter { $0.createdAt > since }.prefix(3)
        let mine = context.visibleMoments(by: nil).filter { $0.createdAt > since }.prefix(2)
        guard !theirs.isEmpty || !mine.isEmpty else { return nil }
        let user = PromptBuilder.userName
        var lines = ["最近的动态（像朋友圈，大家都能看到）："]
        for m in theirs {
            let liked = m.likedByMe ? "，\(user)点了喜欢" : ""
            let t = thread(m, context: context, viewer: persona.id)
            lines.append("- 你在 \(when(m.createdAt)) 发的：「\(m.text)」\(liked)\(t.isEmpty ? "" : "\n  评论：" + t.replacingOccurrences(of: "\n", with: "；"))")
        }
        for m in mine {
            let t = thread(m, context: context, viewer: persona.id)
            lines.append("- \(user)在 \(when(m.createdAt)) 发的：「\(m.text)」\(t.isEmpty ? "" : "\n  评论：" + t.replacingOccurrences(of: "\n", with: "；"))")
        }
        lines.append("聊天时可以自然地提起这些（问 TA 有没有看到、接着评论里的话聊），别生硬。提起你自己发的那条动态时，在那段开头写【动态】，App 会在消息上附上你最近的那条动态。")
        return lines.joined(separator: "\n")
    }
}

/// 读模型写回来的动态格式
enum MomentText {
    struct Post: Equatable {
        var mood = ""
        var text = ""
        /// 相册里的第几张（从 1 开始）
        var photo: Int?
        /// 发成语音时要念的那句
        var spoken: String?
    }

    private static let keys = ["心情", "动态", "配图", "语音"]

    /// 「心情：…」「动态：…」「配图：2」「语音：…」；正文可以有好几行
    static func parse(_ raw: String) -> Post? {
        var fields: [String: String] = [:]
        var current: String?
        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmed
            if let key = keys.first(where: { t.hasPrefix($0 + "：") || t.hasPrefix($0 + ":") }) {
                current = key
                fields[key] = String(t.dropFirst(key.count + 1)).trimmed
            } else if let key = current, !t.isEmpty {
                fields[key, default: ""] += "\n" + t
            }
        }
        let text = clean(fields["动态"] ?? "")
        guard !text.isEmpty else { return nil }
        let photo = fields["配图"].flatMap { Int($0.filter(\.isNumber)) }
        let spoken = fields["语音"].map(clean).flatMap { isNone($0) ? nil : $0 }
        return Post(mood: clean(fields["心情"] ?? "").prefix(4).description, text: text, photo: photo, spoken: spoken)
    }

    static func parseReaction(_ raw: String) -> (like: Bool, comment: String?) {
        var like = false
        var comment: String?
        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmed
            if t.hasPrefix("喜欢") { like = t.contains("是") }
            if t.hasPrefix("评论：") || t.hasPrefix("评论:") {
                let c = clean(String(t.dropFirst(3)))
                comment = isNone(c) ? nil : c
            }
        }
        return (like, comment)
    }

    static func isNone(_ s: String) -> Bool {
        s.isEmpty || ["无", "没有", "不评论", "不配图", "否", "none"].contains(s.lowercased())
    }

    /// 去掉首尾空白和包着的引号
    static func clean(_ raw: String) -> String {
        var s = raw.trimmed
        let pairs: [(Character, Character)] = [("「", "」"), ("“", "”"), ("\"", "\""), ("『", "』")]
        for (open, close) in pairs where s.count >= 2 && s.first == open && s.last == close {
            s = String(s.dropFirst().dropLast()).trimmed
        }
        return s
    }
}
