import Foundation

/// TA 回复的文字怎么处理：拆成几条消息、认出里面的小标记。都是纯文字处理，方便测试
enum ReplyText {
    /// 带格式（代码、列表、表格、标题、引用）的内容整段放在一个气泡里，不拆
    static func looksRich(_ text: String) -> Bool {
        let markers = ["```", "\n#", "\n- ", "\n* ", "\n1. ", "|", "\n> "]
        return text.hasPrefix("#") || text.hasPrefix("- ") || text.hasPrefix("1. ") || markers.contains { text.contains($0) }
    }

    /// 像真人发消息一样拆成几条：空一行就是一条；带格式的或工作汇报（whole）整段一条
    static func paragraphs(_ text: String, whole: Bool) -> [String] {
        if whole || looksRich(text) { return [text.trimmed].filter { !$0.isEmpty } }
        return text.components(separatedBy: "\n\n").map(\.trimmed).filter { !$0.isEmpty }
    }

    // MARK: - 小标记

    /// 【约定:时间|事情】：TA 答应你到某个时间做某件事
    struct Promise: Equatable {
        var time: String
        var what: String
    }

    struct Markers: Equatable {
        /// 去掉标记后的文字
        var body: String
        /// 【引用:…】里写的那几个字
        var quoteKey: String?
        /// 【表情:…】里写的分类名，按出现顺序
        var stickerPacks: [String] = []
        /// 【约定:时间|事情】
        var promises: [Promise] = []
        /// 【取消约定:事情】
        var cancels: [String] = []
        /// 【语音】：这一段用语音说
        var voice = false
        /// 【动态】：TA 提起自己最近发的那条动态
        var moment = false
        /// 要念出来的话：保留语气标签（笑、叹气、停顿），body 里的已经去掉
        var spoken = ""
        /// 【称呼:…】TA 换了个叫你的称呼
        var nickname: String?
        /// 【闹别扭】【和好】
        var sulk = false
        var makeUp = false
        /// 【照片:编号】TA 分享相册里的一张照片
        var photo: Int?
        /// 【表情描述:…】TA 看了你发的表情，记一句它是什么样
        var stickerNote: String?
        /// 【拍一拍】TA 拍了拍你
        var pat = false
        /// 【潜水】群里这条 TA 不说话
        var lurk = false
    }

    // 中英文括号都认：【】 和 []
    private static let quoteMarker = try! Regex("[【\\[]引用[:：]\\s*(.+?)[】\\]]")
    private static let stickerMarker = try! Regex("[【\\[]表情[:：]\\s*(.+?)[】\\]]")
    private static let promiseMarker = try! Regex("[【\\[]约定[:：]\\s*(.+?)\\s*[|｜]\\s*(.+?)[】\\]]")
    private static let cancelMarker = try! Regex("[【\\[]取消约定[:：]\\s*(.+?)[】\\]]")
    private static let voiceMarker = try! Regex("[【\\[]语音[】\\]]")
    private static let momentMarker = try! Regex("[【\\[]动态[】\\]]")
    /// TA 偶尔会用文字假装发表情（比如「[表情]」「【捂脸表情】」）
    private static let fakeSticker = try! Regex("[【\\[][^】\\]]{0,8}表情[^】\\]]{0,8}[】\\]]")
    private static let nicknameMarker = try! Regex("[【\\[]称呼[:：]\\s*(.+?)[】\\]]")
    private static let sulkMarker = try! Regex("[【\\[]闹别扭[】\\]]")
    private static let makeUpMarker = try! Regex("[【\\[]和好[】\\]]")
    private static let photoMarker = try! Regex("[【\\[]照片[:：]\\s*(\\d+)\\s*[】\\]]")
    private static let stickerNoteMarker = try! Regex("[【\\[]表情描述[:：]\\s*(.+?)[】\\]]")
    private static let patMarker = try! Regex("[【\\[]拍一拍[】\\]]")
    private static let lurkMarker = try! Regex("[【\\[]潜水[】\\]]")

    /// 【引用:那句话里的几个字】把你说过的话挂在 TA 这条下面；【表情:分类】发一个表情；假装的表情文字直接去掉
    static func markers(in text: String) -> Markers {
        var body = text
        // 这几个先拿掉：【表情描述:…】不能被当成假装的表情删掉
        var stickerNote: String?
        if let match = body.firstMatch(of: stickerNoteMarker) {
            stickerNote = match.output[1].substring.map { String($0).trimmed }
            body.removeSubrange(match.range)
        }
        var nickname: String?
        if let match = body.firstMatch(of: nicknameMarker) {
            nickname = match.output[1].substring.map { String($0).trimmed }
            body.removeSubrange(match.range)
        }
        var photo: Int?
        if let match = body.firstMatch(of: photoMarker) {
            photo = match.output[1].substring.flatMap { Int(String($0)) }
            body.removeSubrange(match.range)
        }
        let sulk = body.firstMatch(of: sulkMarker) != nil
        body = body.replacing(sulkMarker, with: "")
        let makeUp = body.firstMatch(of: makeUpMarker) != nil
        body = body.replacing(makeUpMarker, with: "")
        let pat = body.firstMatch(of: patMarker) != nil
        body = body.replacing(patMarker, with: "")
        // 潜水：这条整个不发
        let lurk = body.firstMatch(of: lurkMarker) != nil
        if lurk { body = "" }
        var quoteKey: String?
        if let match = body.firstMatch(of: quoteMarker) {
            quoteKey = match.output[1].substring.map { String($0).trimmed }
            body.removeSubrange(match.range)
        }
        var packs: [String] = []
        while let match = body.firstMatch(of: stickerMarker) {
            packs.append(match.output[1].substring.map { String($0).trimmed } ?? "")
            body.removeSubrange(match.range)
        }
        var cancels: [String] = []
        while let match = body.firstMatch(of: cancelMarker) {
            cancels.append(match.output[1].substring.map { String($0).trimmed } ?? "")
            body.removeSubrange(match.range)
        }
        var promises: [Promise] = []
        while let match = body.firstMatch(of: promiseMarker) {
            let time = match.output[1].substring.map { String($0).trimmed } ?? ""
            let what = match.output[2].substring.map { String($0).trimmed } ?? ""
            promises.append(Promise(time: time, what: what))
            body.removeSubrange(match.range)
        }
        let moment = body.firstMatch(of: momentMarker) != nil
        body = body.replacing(momentMarker, with: "")
        let voice = body.firstMatch(of: voiceMarker) != nil
        body = body.replacing(voiceMarker, with: "")
        body = body.replacing(fakeSticker, with: "")
        var markers = Markers(body: VoiceTags.strip(body), quoteKey: quoteKey, stickerPacks: packs, promises: promises, cancels: cancels,
                              voice: voice, moment: moment, spoken: body.trimmed)
        markers.nickname = nickname
        markers.sulk = sulk
        markers.makeUp = makeUp
        markers.photo = photo
        markers.stickerNote = stickerNote
        markers.pat = pat
        markers.lurk = lurk
        return markers
    }

    /// TA 引用的是你哪句话：从最近的往前找，包含这几个字的那条（或这几个字包含那条的开头）
    static func quoted(_ key: String, in messages: [Message]) -> Message? {
        messages.reversed()
            .filter { $0.role == .user && !$0.recalled && !$0.content.isEmpty }
            .first { $0.content.contains(key) || key.contains($0.content.prefix(8)) }
    }

    /// 点引用时找原文：先按编号找；旧消息没有编号（或原文被重新整理过）就按引用的文字找最近的那条
    static func source(ofQuote quote: String, id: UUID?, in messages: [Message]) -> Message? {
        let alive = messages.filter { !$0.recalled }
        if let id, let hit = alive.first(where: { $0.id == id }) { return hit }
        // 引用是「谁：内容」，去掉前面的名字和结尾的省略号
        var body = quote
        if let colon = body.firstIndex(of: "：") { body = String(body[body.index(after: colon)...]) }
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: "…")).trimmed
        guard !body.isEmpty else { return nil }
        return alive.last { m in
            let flat = m.content.replacingOccurrences(of: "\n", with: " ")
            return !flat.isEmpty && (flat.contains(body) || body.contains(flat))
        }
    }

    /// 引用条上那一行：「你：…」，太长就截断
    static func quoteLine(for message: Message) -> String {
        let line = message.content.replacingOccurrences(of: "\n", with: " ")
        return "你：" + (line.count > 60 ? String(line.prefix(60)) + "…" : line)
    }
}
