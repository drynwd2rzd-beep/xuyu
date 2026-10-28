import Foundation
import SwiftData

// MARK: - 取回中断的回复

extension ChatEngine {
    /// App 被关掉时还没收完的回复：电脑上其实已经写好了，连上后按编号取回，补成完整的几条消息
    func recover(context: ModelContext) async {
        guard !recovering, let relay else { return }
        recovering = true
        defer { recovering = false }
        let all = (try? context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.statusRaw == "streaming" }))) ?? []
        let orphans = all.filter { !$0.relayID.isEmpty && buffers[$0.id] == nil }
        let groups = Dictionary(grouping: orphans, by: \.relayID)
        for (relayID, stuck) in groups {
            guard let convo = stuck.first?.conversation, !busy.contains(convo.id) else { continue }
            // 同一次回复里已经发出去的几条
            let siblings = (convo.messages ?? []).filter { $0.relayID == relayID }.sorted { $0.createdAt < $1.createdAt }
            guard let first = siblings.first else { continue }
            var text = ""
            var steps: [String] = []
            var files: [(String, Data)] = []
            do {
                for try await event in relay.resume(relayID) {
                    switch event {
                    case .text(let s): text += s
                    case .step(let s): steps.append(s)
                    case .file(let name, let data): files.append((name, data))
                    case .reasoning: break
                    }
                }
            } catch {
                for m in stuck {
                    m.status = .error
                    m.errorText = (error as? LocalizedError)?.errorDescription ?? "回复被中断"
                }
                try? context.save()
                continue
            }
            // 按和实时一样的规则重新分成几条
            let persona = first.personaID.flatMap { id in context.allPersonas().first { $0.id == id } }
            let parts = ReplyText.paragraphs(text, whole: persona?.canWork == true)
            guard !parts.isEmpty || !files.isEmpty else { continue }
            // 沿用已经发出去的那几条（编号不变，引用它们的地方还能找到原文），不够再补新的
            let start = first.createdAt
            for (i, part) in parts.enumerated() {
                let m: Message
                if i < siblings.count {
                    m = siblings[i]
                } else {
                    m = Message(role: .assistant, content: "", personaID: first.personaID)
                    m.modelLabel = first.modelLabel
                    m.relayID = relayID
                    m.createdAt = start.addingTimeInterval(Double(i) * 0.001)
                    convo.add(m, context: context)
                }
                m.status = .done
                m.errorText = nil
                m.steps = i == 0 ? steps.joined(separator: "\n") : ""
                m.content = persona.map { applyMarkers(part, to: m, persona: $0, convo: convo, context: context) } ?? part
                if m.content.isEmpty && m.steps.isEmpty { context.delete(m) }
            }
            for extra in siblings.dropFirst(parts.count) { context.delete(extra) }
            if let persona {
                for (name, data) in files { deliver(file: name, data: data, from: persona, in: convo, context: context) }
            }
            convo.updatedAt = .now
            try? context.save()
        }
    }
}
