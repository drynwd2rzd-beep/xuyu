import Foundation

/// 消息列表的行：时间分隔 / 消息（连续同一个人的消息合成一组）
struct ChatRow: Identifiable {
    /// 这一行画什么：居中的时间，或者一条消息（first = 这一组的第一条，带名字和头像、和上一组隔开一点）
    enum Kind {
        case stamp(Date)
        case message(Message, first: Bool)
    }

    let id: String
    let kind: Kind

    /// 按时间顺序排好的消息 → 行：隔了 10 分钟以上插一行时间；同一个人隔不到 3 分钟算接着说
    static func build(_ messages: [Message]) -> [ChatRow] {
        var rows: [ChatRow] = []
        var prev: Message?
        for m in messages {
            var first = true
            if let prev {
                let gap = m.createdAt.timeIntervalSince(prev.createdAt)
                if gap > 600 {
                    rows.append(ChatRow(id: "t-\(m.id)", kind: .stamp(m.createdAt)))
                } else {
                    let same = prev.role == m.role && prev.personaID == m.personaID
                    first = !(same && gap < 180)
                }
            } else {
                rows.append(ChatRow(id: "t-\(m.id)", kind: .stamp(m.createdAt)))
            }
            rows.append(ChatRow(id: m.id.uuidString, kind: .message(m, first: first)))
            prev = m
        }
        return rows
    }

    /// 每一组（同一个人连着说的几条）最后一条的行 id：这一条的气泡带小尾巴（像 iMessage）。
    /// 下一行不是「接着说」的消息（是时间、换了人、或者已经到底）就算这一组说完了
    static func groupEnds(_ rows: [ChatRow]) -> Set<String> {
        var ends: Set<String> = []
        for (index, row) in rows.enumerated() {
            guard case .message = row.kind else { continue }
            let next = rows.indices.contains(index + 1) ? rows[index + 1].kind : nil
            if case .message(_, first: false) = next { continue }
            ends.insert(row.id)
        }
        return ends
    }
}

/// 聊天页此刻要画的那一屏：排哪些行、「正在输入」的小点放哪、「已读」挂在哪条下面、最下面一截长什么样。
/// 纯函数：只看对话里的消息、正在生成的缓冲和「现在」，不碰界面状态，聊天页只负责把结果画出来
struct ChatRows {
    /// 要画的行（「正在输入」的那条接在最后）
    let rows: [ChatRow]
    /// 每一组最后一条的行 id（气泡带小尾巴，见 ChatRow.groupEnds）
    let groupEnds: Set<String>
    /// 前面还有没排进来的更早消息：顶上显示「查看更早的消息」
    let hasEarlier: Bool
    /// TA 已经开始回、但这句还没打完（只显示跳动的小点）的那条
    let typing: Message?
    /// 除了「正在输入」以外的最后一条
    let last: Message?
    /// 「已读」挂在哪条下面
    let receipt: UUID?
    /// 正在逐字出现的那条的缓冲：字数变了聊天跟着往下走
    let live: StreamBuffer?
    /// 最下面那一截的样子：多了一行、小点变成了文字、「已读」出现或消失，都算变了（变了就滚到最新）
    let tail: String

    /// 算出这一屏：只排最近 limit 条（聊天页不用懒加载，见 ChatView），到点才出现的消息还没到就不排
    static func make(_ convo: Conversation, limit: Int, buffers: [UUID: StreamBuffer], now: Date) -> ChatRows {
        let all = convo.visibleMessages(at: now)
        // 只排版最近的一段，避免懒加载估算高度导致跳动；更早的按需加载
        let window = Array(all.suffix(limit))
        // 「正在输入」的小点不按时间排，永远在最底下（像 iMessage）：你这时再发消息，会插在小点上面
        let typing = window.last { isTypingOnly($0, buffers: buffers) }
        let messages = window.filter { !isTypingOnly($0, buffers: buffers) }
        // 打字的那条接在最后：和打好后的消息是同一行（同一个 id），小点会在原地变成文字，而不是删掉再冒出新的一行
        var rows = ChatRow.build(messages)
        if let typing {
            // 和它变成文字以后用同一条规则（同一个人、隔不到 3 分钟算接着说）：小点变成字的那一刻，名字和头像不会突然冒出来
            let same = messages.last?.role == .assistant && messages.last?.personaID == typing.personaID
            let gap = messages.last.map { now.timeIntervalSince($0.createdAt) } ?? .infinity
            let first = !(same && gap < 180)
            rows.append(ChatRow(id: typing.id.uuidString, kind: .message(typing, first: first)))
        }
        let live = (typing ?? messages.last).flatMap { buffers[$0.id] }
        let receipt = readReceipt(messages, buffers: buffers, now: now)
        let tail = [rows.last?.id ?? "", typing == nil ? "" : "typing", messages.last?.id.uuidString ?? "",
                    "\(messages.last?.content.count ?? 0)", receipt?.uuidString ?? ""].joined(separator: "|")
        return ChatRows(rows: rows, groupEnds: ChatRow.groupEnds(rows), hasEarlier: all.count > window.count, typing: typing, last: messages.last,
                        receipt: receipt, live: live, tail: tail)
    }

    /// TA 已经开始回、但这句还没打完（只显示跳动的小点）。只看「还藏着」这个开关，不读正文，免得每冒一个字整个列表都重排
    static func isTypingOnly(_ m: Message, buffers: [UUID: StreamBuffer]) -> Bool {
        guard m.status == .streaming, let buffer = buffers[m.id] else { return false }
        return buffer.hold && buffer.steps.isEmpty
    }

    /// 「已读」挂在哪条下面：你最后一条、TA 已经看过的消息。TA 正在打字（只有跳动的小点）时还留着，
    /// 等 TA 第一句话真的冒出来才淡出，和 iMessage 一样
    static func readReceipt(_ messages: [Message], buffers: [UUID: StreamBuffer], now: Date) -> UUID? {
        // 「通话时长」气泡、「拍了拍」那一行不算：已读只挂在真正发出去的消息下面
        guard let index = messages.lastIndex(where: { $0.role == .user && !$0.recalled && $0.kind != .call && $0.kind != .nudge })
        else { return nil }
        let mine = messages[index]
        // TA 在忙没看到：已读时间排在以后，到那时才显示「已读」
        guard let read = mine.readAt, read <= now else { return nil }
        let replied = messages[(index + 1)...].contains { m in
            guard m.status == .streaming else { return true }
            // 只看「还藏着」这一个开关，不读正文，免得每冒一个字整个列表都重排一次
            guard let buffer = buffers[m.id] else { return false }
            return !buffer.hold || !buffer.steps.isEmpty
        }
        return replied ? nil : mine.id
    }
}
