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

    struct Markers: Equatable {
        /// 去掉标记后的文字
        var body: String
        /// 【引用:…】里写的那几个字
        var quoteKey: String?
        /// 【表情:…】里写的分类名，按出现顺序
        var stickerPacks: [String] = []
    }

    // 中英文括号都认：【】 和 []
    private static let quoteMarker = try! Regex("[【\\[]引用[:：]\\s*(.+?)[】\\]]")
    private static let stickerMarker = try! Regex("[【\\[]表情[:：]\\s*(.+?)[】\\]]")
    /// TA 偶尔会用文字假装发表情（比如「[表情]」「【捂脸表情】」）
    private static let fakeSticker = try! Regex("[【\\[][^】\\]]{0,8}表情[^】\\]]{0,8}[】\\]]")

    /// 【引用:那句话里的几个字】把你说过的话挂在 TA 这条下面；【表情:分类】发一个表情；假装的表情文字直接去掉
    static func markers(in text: String) -> Markers {
        var body = text
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
        body = body.replacing(fakeSticker, with: "")
        return Markers(body: body.trimmed, quoteKey: quoteKey, stickerPacks: packs)
    }

    /// TA 引用的是你哪句话：从最近的往前找，包含这几个字的那条（或这几个字包含那条的开头）
    static func quoted(_ key: String, in messages: [Message]) -> Message? {
        messages.reversed()
            .filter { $0.role == .user && !$0.recalled && !$0.content.isEmpty }
            .first { $0.content.contains(key) || key.contains($0.content.prefix(8)) }
    }

    /// 引用条上那一行：「你：…」，太长就截断
    static func quoteLine(for message: Message) -> String {
        let line = message.content.replacingOccurrences(of: "\n", with: " ")
        return "你：" + (line.count > 60 ? String(line.prefix(60)) + "…" : line)
    }
}
