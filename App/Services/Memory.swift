import Foundation
import SwiftData

/// 长期记忆：聊天多了以后，把更早的部分总结成要点，之后每次聊天都带上。
/// 最近的聊天整段保留、攒够了才整段挪进记忆，这样发给模型的开头大部分时间不变，提示缓存一直有效。
@MainActor
enum Memory {
    /// 没总结的消息超过这么多条，就整理一次
    nonisolated static let trigger = 60
    /// 整理后保留最近这么多条逐字发送
    nonisolated static let keep = 20
    /// 万一整理一直失败，最多也只逐条发这么多
    nonisolated static let maxWindow = 90
    /// 第一次整理很长的老记录时，最多读这么多条
    nonisolated static let maxChunk = 240

    private static var working: Set<UUID> = []

    static func updateIfNeeded(_ convo: Conversation, members: [Persona], context: ModelContext, relay: RelayClient) async {
        guard !working.contains(convo.id), let persona = members.first else { return }
        let pending = convo.visibleMessages().filter { $0.createdAt > convo.memoryUntil && $0.status != .error }
        guard pending.count > trigger else { return }
        let chunk = Array(pending.dropLast(keep).suffix(maxChunk))
        guard let last = chunk.last else { return }

        working.insert(convo.id)
        defer { working.remove(convo.id) }

        let user = PromptBuilder.userName
        let names = Dictionary(members.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let who = convo.isGroup ? "群聊「\(convo.displayTitle(members))」里的大家" : "「\(persona.name)」"
        let prompt = """
        你在帮\(who)整理和\(user)聊天的长期记忆。下面是现有的记忆，和一段更早的聊天记录。

        现有记忆：
        \(convo.memory.trimmed.isEmpty ? "（还没有）" : convo.memory.trimmed)

        更早的聊天记录：
        \(PromptBuilder.transcript(chunk, names: names))

        请输出更新后的完整记忆：
        - 保留关于\(user)的重要信息：身份、喜好、习惯、经历、正在做的事和计划、重要的日子、情绪上的变化，以及你们之间的约定、昵称、梗。
        - 合并新信息，删掉过时、重复或琐碎的内容；能写日期的写上日期。
        - 用简洁的中文要点，每条一行，以「- 」开头，最多 25 条，总共不超过 600 字。
        只输出记忆本身，不要别的话。
        """
        let request = RelayRequest(engine: persona.engine.rawValue, model: PromptBuilder.model(for: persona), effort: "low",
                                   system: "你是一个细心的记录者，只负责整理聊天里值得长期记住的事。", prompt: prompt)
        guard let text = try? await relay.complete(request), !text.trimmed.isEmpty else { return }
        convo.memory = String(text.trimmed.prefix(1500))
        convo.memoryUntil = last.createdAt
        context.persist()
    }

    /// 清空聊天记录时，记忆也一起重来
    static func reset(_ convo: Conversation) {
        convo.memory = ""
        convo.memoryUntil = .distantPast
    }
}
