import Foundation

// MARK: - 谁来回

extension ChatEngine {
    /// 谁来回这句话：单聊是 TA；群里 @ 了谁就谁回，没 @ 谁时有人潜水（@所有人 时大家都回）。
    /// 你发消息、连上电脑后回排队的消息都按它定（审查 Z-274：以前两处各写一份）
    static func whoAnswers(_ text: String, convo: Conversation, members: [Persona]) -> [Persona] {
        let chosen = responders(for: text, convo: convo, members: members)
        // 群里没 @ 谁：不是每个人都回，有人潜水
        if convo.isGroup, members.count > 1, chosen.count == members.count, !text.contains("@所有人") {
            return lurking(members)
        }
        return chosen
    }

    /// 群聊：@ 了谁就只让谁回复；@所有人 或没有 @ 时所有成员依次回复
    static func responders(for text: String, convo: Conversation, members: [Persona]) -> [Persona] {
        guard convo.isGroup else { return Array(members.prefix(1)) }
        if text.contains("@所有人") { return members }
        let mentioned = members.filter { text.contains("@\($0.name)") }
        return mentioned.isEmpty ? members : mentioned
    }

    /// 群里没 @ 谁：不是每个人都回，有人潜水（至少一个人回）
    static func lurking(_ members: [Persona]) -> [Persona] {
        let order = members.shuffled()
        guard let first = order.first else { return [] }
        return [first] + order.dropFirst().filter { _ in Double.random(in: 0..<1) < 0.6 }
    }

    /// 合并两批要回复的人，去掉重复，保持先后顺序
    static func merge(_ a: [Persona], _ b: [Persona]) -> [Persona] {
        a + b.filter { p in !a.contains { $0.id == p.id } }
    }
}
