import SwiftUI
import SwiftData

enum Seeder {
    @MainActor
    static func prepare(_ context: ModelContext) {
        if DemoMode.isOn {
            DemoData.populate(context)
            return
        }
        let streaming = (try? context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.statusRaw == "streaming" }))) ?? []
        for m in streaming {
            // 有回复编号的先留着，连上电脑后去取回完整内容（ChatEngine.recover）
            if !m.relayID.isEmpty { continue }
            if m.content.isEmpty {
                m.status = .error
                m.errorText = "回复被中断"
            } else {
                m.status = .done
            }
        }
        if ((try? context.fetchCount(FetchDescriptor<Persona>())) ?? 0) == 0 {
            let claude = Persona(name: "Claude", engine: .claude, tint: 0x1E1E1F, bio: "温柔聪明的伙伴",
                                 systemPrompt: "你是 Claude，用户的私人伙伴。说话自然、温柔、简洁，像朋友聊天；需要时用 Markdown 组织内容；不确定的事情坦诚说明。")
            let codex = Persona(name: "Codex", engine: .codex, tint: 0xE7E3DA, bio: "擅长代码和动手",
                                systemPrompt: "你是 Codex，用户的技术伙伴。回答务实、清楚，给出可以直接执行的步骤。")
            codex.sortIndex = 1
            context.insert(claude)
            context.insert(codex)
            _ = context.chat(for: claude)
            _ = context.chat(for: codex)
        }
        try? context.save()
    }
}
