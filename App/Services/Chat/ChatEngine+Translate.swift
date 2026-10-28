import SwiftUI
import SwiftData

// MARK: - 翻译

extension ChatEngine {
    /// 把一条消息翻译出来，显示在这条消息下面：原文不是中文就翻成中文，原文是中文就翻成韩语。
    /// 用电脑上的模型、低强度，省额度；翻好的存在消息里，下次打开直接显示
    func translate(_ message: Message, context: ModelContext) async {
        let text = message.content.trimmed
        guard !text.isEmpty, !translating.contains(message.id), let relay else { return }
        guard let persona = message.personaID.flatMap({ context.persona($0) }) ?? context.allPersonas().first else { return }
        withAnimation(Motion.spring) { _ = translating.insert(message.id) }
        defer { withAnimation(Motion.spring) { _ = translating.remove(message.id) } }
        let request = RelayRequest(engine: persona.engine.rawValue, model: PromptBuilder.model(for: persona), effort: "low",
                                   system: "你是翻译，只输出译文，不加解释、引号或注音。",
                                   prompt: """
                                   把下面这段话翻译出来：原文不是中文就翻成中文；原文已经是中文就翻成韩语。保留原来的语气和口吻，自然口语。

                                   \(text)
                                   """)
        guard let result = try? await relay.complete(request), !result.trimmed.isEmpty else { return }
        withAnimation(Motion.spring) { message.translation = result.trimmed }
        context.persist()
    }

    /// 收起翻译（下次再长按「翻译」会重新翻）
    func hideTranslation(_ message: Message, context: ModelContext) {
        withAnimation(Motion.spring) { message.translation = "" }
        context.persist()
    }
}
