import Foundation
import SwiftData
import SwiftUI

/// 一次回复的全过程：TA 先冒出「正在输入」，边收字边按空行一段一段发出去（打字犹豫、打字节奏、语音、标记），
/// 你中途插话就把这句说完停下，最后收尾（出错、被停下、重新生成换掉旧的、通知）。
/// 以前这些都写在 ChatEngine.reply 一个 250 行的函数里，靠十几个局部变量和 6 个内嵌函数（审查 Z-274、Z-329）。
/// 时序和动画调用和原来一模一样：改这里要按 MOTION-5 在真机上录一段对比
@MainActor
final class ReplySession {
    private let engine: ChatEngine
    private let persona: Persona
    private let convo: Conversation
    private let context: ModelContext
    private let request: RelayRequest
    private let relayID: String
    /// 正在写的这条气泡和它的流式内容：每发出一段就换成新的一条
    private var message: Message
    private var buffer: StreamBuffer
    /// 已经发出去的几段（语音记成「[语音]」）：最后一段用来发通知
    private var sent: [String] = []
    /// 工作模式、带格式或很长的认真回答：边写边显示、整段一条，不拆
    private var rich: Bool
    private var lastCommit = ContinuousClock.now
    /// 这一轮已经犹豫过了（每轮最多一次）
    private var hesitated = false
    private let voiceOn: Bool
    /// 你在 TA 说话途中又发了消息：TA 把正在打的这句发完就停下，剩下没说的不再接着念，回头看了你的新消息再回
    private var interrupted = false
    /// 最后一段如果是语音：念好的音频
    private var lastAudio: Data?
    /// 收到了、还没放进气泡的字（每 50 毫秒放一次，不每个字都刷新）
    private var pendingText = ""
    private var pendingReasoning = ""

    private init(engine: ChatEngine, persona: Persona, convo: Conversation, context: ModelContext,
                 request: RelayRequest, relayID: String, message: Message, buffer: StreamBuffer) {
        self.engine = engine
        self.persona = persona
        self.convo = convo
        self.context = context
        self.request = request
        self.relayID = relayID
        self.message = message
        self.buffer = buffer
        // 工作模式的回复是一份完整的汇报，不拆成几条
        rich = persona.canWork
        engine.typing[convo.id] = persona.id
        // 像真人一样一句一句发：每说完一段（空一行），就把这段作为一条消息发出去，接着「输入中」
        // 闲聊时：一段写完才整条冒出来（之前只显示「正在输入」）；带格式、很长的认真回答或工作模式，边写边显示、整段一条
        buffer.hold = !rich
        lastCommit = .now
        voiceOn = Voice.enabled(for: persona)
    }

    /// 拼好请求、冒出第一个「正在输入」的气泡
    static func begin(engine: ChatEngine, persona: Persona, convo: Conversation, members: [Persona],
                      context: ModelContext, discussing: Bool) -> ReplySession {
        // 正在打字、还没出字的那条不算聊天记录；正要被重新生成换掉的那条也不算（TA 不该看到自己上一版的回答）
        let old = engine.replacing[convo.id]?.id
        let history = convo.visibleMessages().filter { $0.status != .streaming && $0.id != old }
        let request = PromptBuilder.request(for: persona, convo: convo, members: members, history: history, discussing: discussing,
                                            diaryNotes: Companion.myDiaryNotes(context: context),
                                            sharedMemory: PromptBuilder.sharedMemory(of: persona, besides: convo, context: context),
                                            stickerCategories: PromptBuilder.stickerCategories(context: context),
                                            appointments: Appointments.summary(persona: persona, convo: convo))
        let relayID = UUID().uuidString
        let (message, buffer) = engine.firstBubble(persona, in: convo, context: context, label: request.model, relayID: relayID)
        context.persist()
        return ReplySession(engine: engine, persona: persona, convo: convo, context: context,
                            request: request, relayID: relayID, message: message, buffer: buffer)
    }

    // MARK: - 全过程

    func run() async {
        do {
            guard let relay = engine.relay else { throw RelayError.notConfigured }
            try await receive(from: relay)
            if interrupted {
                // 刚发完的那句就是这一轮的最后一句：后面的不要了
                if let last = sent.last { engine.notify(convo: convo, persona: persona, text: last) }
                convo.updatedAt = .now
                if engine.router?.openConversation == convo.id { convo.lastReadAt = .now }
                context.persist()
                return
            }
            try await finishText()
        } catch {
            if keepTyping(after: error) { return }
        }
        settle()
    }

    /// 边收边放：每 50 毫秒把收到的字放进气泡，凑够一段就发出去；你插话了就停
    private func receive(from relay: any RelayTransport) async throws {
        var lastFlush = ContinuousClock.now
        for try await event in relay.run(request, id: relayID) {
            switch event {
            case .text(let s): pendingText += s
            case .reasoning(let s): pendingReasoning += s
            case .approval(let req, let text):
                // 断线重连后中继会把同一个问题再问一次：已经在等的就不重复弹
                if buffer.approval?.req != req {
                    engine.speaking.insert(convo.id)
                    withAnimation(Motion.bubble) { buffer.approval = PendingApproval(req: req, text: text) }
                    // 不在这个聊天里（或者 App 在后台）：提醒你去点
                    engine.notify(convo: convo, persona: persona, text: String(localized: "想\(text)，等你确认"))
                }
            case .step(let s):
                // 已经开始操作电脑了：你再插话也不打断重来，免得同样的操作做两遍
                engine.speaking.insert(convo.id)
                buffer.steps.append(s)
                message.steps = buffer.steps.joined(separator: "\n")
            case .file(let name, let data):
                // 工作模式发回手机的文件：单独一条文件消息
                engine.deliver(file: name, data: data, from: persona, in: convo, context: context)
            }
            if ContinuousClock.now - lastFlush > .milliseconds(50) {
                buffer.text += pendingText
                buffer.reasoning += pendingReasoning
                pendingText = ""
                pendingReasoning = ""
                lastFlush = .now
                // 只有你屏幕上已经看到 TA 在说话，才算「开口了」；还藏着没显示时被你插话，就重新看全部再回
                if (!buffer.text.trimmed.isEmpty && !buffer.hold) || !buffer.steps.isEmpty {
                    engine.speaking.insert(convo.id)
                    // 边写边显示的认真回答：新的开始出字了，旧的那条退场
                    if engine.replacing[convo.id] != nil { withAnimation(Motion.bubble) { engine.retireReplaced(convo.id, context: context) } }
                }
                if !rich && ReplyText.looksRich(buffer.text) { becomeRich() }
                await commitParagraphs()
                if interrupted { return }
            }
        }
    }

    /// 收完了：剩下的字放进去，最后一段也按打字节奏出现
    private func finishText() async throws {
        buffer.text += pendingText
        buffer.reasoning += pendingReasoning
        // 被你插话打断了：还藏着没显示的半段话直接丢掉
        if Task.isCancelled { throw CancellationError() }
        await commitParagraphs()
        if buffer.text.trimmed.isEmpty && sent.isEmpty && !Task.isCancelled { throw RelayError.server("没有收到回复。") }
        // 最后一条也按打字节奏出现（只有一句话的回复，犹豫也在这里）
        if !rich && !buffer.text.trimmed.isEmpty {
            if sent.isEmpty { await hesitate() }
            await pace(for: buffer.text)
        }
        if !rich { lastAudio = await record(buffer.text) }
        if buffer.hold { message.createdAt = max(.now, message.createdAt) }
        buffer.hold = false
        message.status = .done
    }

    /// 出错或被停下。返回 true：你插话打断了还没开口的 TA，这个「正在输入」留着给下一轮接着用，不收尾
    private func keepTyping(after error: Error) -> Bool {
        if (Task.isCancelled || error is CancellationError) && buffer.hold && engine.pending[convo.id] != nil {
            // 你插话打断了还没开口的 TA：这个「正在输入」留着，TA 看完你的新消息接着在里面打
            buffer.text = ""
            buffer.reasoning = ""
            engine.carried[convo.id] = message
            return true
        }
        if Task.isCancelled || error is CancellationError {
            message.status = .done
            if buffer.hold { buffer.text = "" }
        } else {
            message.status = .error
            message.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return false
    }

    /// 最后一句落定：小点变成文字（或者整条拿掉）、重新生成换下旧的、发通知
    private func settle() {
        let final = message.status == .done
            ? engine.applyMarkers(buffer.text.trimmed, to: message, persona: persona, convo: convo, context: context)
            : buffer.text.trimmed
        // 重新生成出错了、新的一句也没说出来：失败的这条不要，原来那条留着，只提示一下
        let failedRedo = message.status == .error && engine.replacing[convo.id] != nil
        let saidSomething = message.status == .done && (!final.isEmpty || !buffer.steps.isEmpty)
        // 最后一句也和前面一样：小点变成文字、气泡撑开，在同一个平滑动画里完成
        withAnimation(Motion.bubble) {
            engine.buffers[message.id] = nil
            message.content = final
            message.reasoning = buffer.reasoning.trimmed
            message.steps = buffer.steps.joined(separator: "\n")
            if failedRedo || (message.status == .done && message.content.isEmpty && message.steps.isEmpty) {
                context.delete(message)
            } else if message.status == .done, let lastAudio {
                attach(lastAudio, to: message)
            }
            if saidSomething { engine.retireReplaced(convo.id, context: context) }
        }
        // 没换成（出错、被你停下）：原来那条照旧留着
        engine.replacing[convo.id] = nil
        if failedRedo { engine.redoFailed.insert(convo.id) }
        if !final.isEmpty && message.status == .done {
            sent.append(lastAudio == nil ? final : "[语音]")
        }
        if let last = sent.last {
            engine.notify(convo: convo, persona: persona, text: last)
        }
        convo.updatedAt = .now
        if engine.router?.openConversation == convo.id { convo.lastReadAt = .now }
        context.persist()
    }

    // MARK: - 一段一段发

    /// 凑够一段（空一行）就发出去，再开一个新的「正在输入」接着写
    private func commitParagraphs() async {
        while !rich, !interrupted, let range = buffer.text.range(of: "\n\n") {
            let head = String(buffer.text[..<range.lowerBound]).trimmed
            let rest = String(buffer.text[range.upperBound...])
            guard !head.isEmpty else { buffer.text = rest; continue }
            // 带格式或特别长的一段：是认真的回答，整段放一条，不拆
            if ReplyText.looksRich(head) || head.count > 140 { becomeRich(); return }
            if sent.isEmpty { await hesitate() }
            await pace(for: head)
            let audio = await record(head)
            let leftThought = reveal(head, audio: audio)
            engine.speaking.insert(convo.id)
            lastCommit = .now
            // 像 iMessage：这一句冒出来以后停一小会儿，下一条的「正在输入」才出现，
            // 不和这句变成文字的动画挤在同一瞬间（停顿算在下一句的打字时间里，总节奏不变）
            if engine.pending[convo.id] == nil { try? await Task.sleep(for: .milliseconds(450)) }
            if engine.pending[convo.id] != nil {
                interrupted = true
                context.persist()
                return
            }
            (message, buffer) = engine.newBubble(persona, in: convo, context: context, label: request.model, relayID: relayID)
            buffer.hold = true
            if let leftThought { Cleanup.saveThought(leftThought, for: message.id, context: context) }
            buffer.text = rest
            context.persist()
        }
    }

    /// 这一段冒出来：小点变成文字、气泡撑开、「已读」淡出，放在同一个平滑动画里一起完成。
    /// 返回这一段只写了心声、没说话时留给下一条的心声
    private func reveal(_ head: String, audio: Data?) -> String? {
        // 藏着打字的这条，以真正冒出来的时刻为准
        message.createdAt = max(.now, message.createdAt)
        let cleaned = engine.applyMarkers(head, to: message, persona: persona, convo: convo, context: context)
        // 这一段只写了心声、没说话：心声留给下一条
        let leftThought = cleaned.isEmpty ? Thoughts.shared.text(message.id) : nil
        withAnimation(Motion.bubble) {
            // 重新生成：新的第一句出来了，旧的那条这时才退场
            engine.retireReplaced(convo.id, context: context)
            engine.buffers[message.id] = nil
            if cleaned.isEmpty {
                // 这一段只有一个表情：表情已经单独发出，空气泡不要了
                context.delete(message)
            } else {
                message.content = cleaned
                message.status = .done
                if let audio { attach(audio, to: message) }
            }
        }
        if !cleaned.isEmpty { sent.append(audio == nil ? cleaned : "[语音]") }
        return leftThought
    }

    private func becomeRich() {
        rich = true
        buffer.hold = false
    }

    // MARK: - 像真人

    /// 打字犹豫：开口前偶尔「正在输入」淡掉一会儿再出现，像打了几个字又删掉重想（开了「真人节奏」才会，每轮最多一次）
    private func hesitate() async {
        guard !hesitated, !rich, HumanTouch.pace(persona), !DemoMode.isOn else { return }
        hesitated = true
        guard Double.random(in: 0..<1) < 0.18 else { return }
        withAnimation(Motion.fade) { buffer.paused = true }
        try? await Task.sleep(for: .seconds(Double.random(in: 1.2...2.4)))
        withAnimation(Motion.fade) { buffer.paused = false }
        try? await Task.sleep(for: .seconds(Double.random(in: 0.7...1.4)))
    }

    /// 像真人打字：下一条按长度留出 0.8～3 秒的「打字时间」，期间显示跳动的小点
    private func pace(for text: String) async {
        guard !sent.isEmpty else { return }
        let wait = Duration.seconds(min(3.0, max(0.8, 0.5 + Double(text.count) * 0.06)))
        let remain = wait - (ContinuousClock.now - lastCommit)
        if remain > .zero { try? await Task.sleep(for: remain) }
    }

    // MARK: - 语音

    /// 这一段 TA 想用语音说（开头写了【语音】）：先用 TA 的声音念好，念的时候还是「正在输入」；
    /// 没设声音、念不出来（比如额度用完）就照常发文字
    private func record(_ text: String) async -> Data? {
        guard voiceOn else { return nil }
        let marks = ReplyText.markers(in: text)
        guard marks.voice, !marks.body.isEmpty else { return nil }
        do {
            return try await Voice.speak(marks.spoken, for: persona)
        } catch let failure as Voice.Failure {
            // 额度用完、密钥不对：照常发文字，但告诉你一声（以前语音就这么悄悄不发了）
            switch failure {
            case .quota, .badKey, .noKey:
                if !engine.voiceWarned {
                    engine.voiceWarned = true
                    engine.notices[convo.id] = String(localized: "语音没发出去：\(failure.localizedDescription)")
                }
            case .other: break
            }
            return nil
        } catch {
            return nil
        }
    }

    private func attach(_ audio: Data, to m: Message) {
        m.kindRaw = MessageKind.voice.rawValue
        let a = Attachment(kind: .audio, fileName: "voice.mp3", data: audio, order: 0)
        a.message = m
        context.insert(a)
        // 开了「自动翻译语音」：语音一发出就在下面翻好
        if persona.autoTranslate {
            let engine = engine
            let context = context
            Task { await engine.translate(m, context: context) }
        }
    }
}
