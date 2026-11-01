import Foundation

/// 拼提示词用的底层小零件：你的称呼、聊天记录转成文字、「记忆 + 最近聊天」、天气一行、低强度的一次性请求。
/// 只读数据模型和设置（加上心声、视频卡片、通话内容这几份小存储），不回头调用拼请求的服务，
/// 所以 Memory、World、MomentsEngine 这些服务都能放心用它，不会和 PromptBuilder 互相绕圈（审查 Z-273、Z-328）。
/// 在主线程上：要读角色和对话（SwiftData 模型）
@MainActor
enum PromptParts {
    // MARK: - 称呼和模型

    /// 提示词里怎么称呼你：你在设置里填的称呼，没填就是「用户」
    static var userName: String {
        let n = Prefs.nicknameValue
        return n.isEmpty ? "用户" : n
    }

    /// 这位角色用的模型：没单独选就用设置里的默认模型
    static func model(for persona: Persona) -> String {
        persona.model.isEmpty ? Prefs.defaultModel(for: persona.engine) : persona.model
    }

    /// 这位角色的推理强度：没单独选就用设置里的默认
    static func effort(for persona: Persona) -> String {
        persona.effort.isEmpty ? Prefs.defaultEffort(for: persona.engine) : persona.effort
    }

    // MARK: - 聊天记录

    /// 一条消息写成一行：[时间] 谁：说了什么。图片、文件、语音、通话这类写成括号里的说明
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

    /// 一段聊天记录：每天开头写一行日期，出错的消息不算
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

    // MARK: - 记忆和最近的聊天

    /// 「你记得的关于你的事」+「下面是你们最近的聊天记录」，主动消息、追问、动态、约定、补一句、通话都用这一段，措辞和条数上限只在这里定。
    /// - memory：从这段对话的长期记忆里取；传 nil 就不带记忆（补一句、通话：刚刚还在聊，用不着）
    /// - recent：最多带最近几条（`Limits.Prompt` 里按用途给的数）
    /// - between：夹在记忆和聊天中间的资料（比如你最近发的动态）
    static func contextBlock(memory convo: Conversation?, history: [Message], recent: Int,
                             names: [UUID: String], between: String = "") -> String {
        var parts: [String] = []
        if let memory = convo?.memory.trimmed, !memory.isEmpty {
            parts.append("你记得的关于\(userName)的事：\n\(memory)")
        }
        if !between.isEmpty { parts.append(between) }
        let chat = Array(history.suffix(recent))
        parts.append("下面是你们最近的聊天记录：\n\n" + (chat.isEmpty ? "（还没有聊过）" : transcript(chat, names: names)))
        return parts.joined(separator: "\n\n")
    }

    /// 「你那边的天气：……」，没取到天气时是空的
    static var weatherLine: String {
        Weather.summary.map { "\(userName)那边的天气：\($0)" } ?? ""
    }

    // MARK: - 低强度的一次性请求

    /// 今日一句、日记、翻译、记忆整理这类轻任务：用低强度省额度。
    /// system 由调用方给：要角色口吻的用 `PromptBuilder.lightRequest`（带整份人设），
    /// 第三方任务（翻译、整理记忆）只给一句任务说明，不带角色底稿（PROMPT-9）
    static func lightRequest(_ persona: Persona, _ prompt: String, system: String) -> RelayRequest {
        RelayRequest(engine: persona.engine.rawValue, model: model(for: persona), effort: "low", system: system, prompt: prompt)
    }
}
