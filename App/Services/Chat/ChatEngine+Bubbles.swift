import Foundation
import SwiftData
import SwiftUI

// MARK: - 「正在输入」的气泡

extension ChatEngine {
    /// 一位角色说一次话（一次回复的全过程在 ReplySession）
    func reply(as persona: Persona, in convo: Conversation, members: [Persona], context: ModelContext,
               discussing: Bool = false) async {
        await ReplySession.begin(engine: self, persona: persona, convo: convo, members: members, context: context,
                                 discussing: discussing).run()
    }

    /// 留着的「正在输入」最后没用上（比如换了别人回、或者不用回了）：轻轻撤掉
    func dropCarried(_ convoID: UUID, context: ModelContext) {
        guard let kept = carried.removeValue(forKey: convoID) else { return }
        withAnimation(Motion.bubble) {
            buffers[kept.id] = nil
            context.delete(kept)
        }
        context.persist()
    }

    /// 重新生成的新回复已经出现：把旧的那条拿掉（放在调用处的动画里一起完成）
    func retireReplaced(_ convoID: UUID, context: ModelContext) {
        // 这期间你自己把旧的删掉了：不用再删
        guard let old = replacing.removeValue(forKey: convoID), old.modelContext != nil, !old.isDeleted else { return }
        context.delete(old)
    }

    /// 这一轮的第一个气泡：被插话时留下的那个「正在输入」接着用，否则新开一个
    func firstBubble(_ persona: Persona, in convo: Conversation, context: ModelContext, label: String,
                     relayID: String) -> (Message, StreamBuffer) {
        if let kept = carried[convo.id], kept.personaID == persona.id, let buffer = buffers[kept.id] {
            carried[convo.id] = nil
            kept.modelLabel = label
            kept.relayID = relayID
            return (kept, buffer)
        }
        dropCarried(convo.id, context: context)
        return newBubble(persona, in: convo, context: context, label: label, relayID: relayID)
    }

    func newBubble(_ persona: Persona, in convo: Conversation, context: ModelContext, label: String,
                   relayID: String) -> (Message, StreamBuffer) {
        let message = Message(role: .assistant, content: "", personaID: persona.id)
        // 排在已经出现的消息后面（比如上一段刚带出的表情）
        if let latest = convo.lastVisible()?.createdAt { message.createdAt = max(.now, latest.addingTimeInterval(0.00001)) }
        message.status = .streaming
        message.modelLabel = label
        message.relayID = relayID
        let buffer = StreamBuffer()
        buffer.hold = true
        buffers[message.id] = buffer
        // 「正在输入」的气泡出现时，上面的消息平滑地往上让开，不会突然冒出来
        withAnimation(Motion.bubble) {
            convo.add(message, context: context)
        }
        return (message, buffer)
    }

    /// 演示（云端录屏检查动画用）：走和真回复一样的路径，先冒出「正在输入」的小点，过一会儿在原地变成文字
    func demoReply(_ text: String, as persona: Persona, in convo: Conversation, context: ModelContext) async {
        let (message, _) = newBubble(persona, in: convo, context: context, label: "", relayID: "")
        try? await Task.sleep(for: .seconds(1.6))
        message.createdAt = max(.now, message.createdAt)
        withAnimation(Motion.bubble) {
            buffers[message.id] = nil
            message.content = text
            message.status = .done
        }
    }
}
