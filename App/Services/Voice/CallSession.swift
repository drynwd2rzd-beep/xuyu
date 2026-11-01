import SwiftUI
import SwiftData
import Speech
import AVFoundation
import Observation

/// 语音通话：你说话 → 停顿一下自动发出 → TA 一边想一边用自己的声音一句一句念出来，字幕下面带韩语翻译。
/// TA 说话时点中间的头像可以打断。挂断后聊天里留一个「通话时长」气泡，点开看通话内容（见 CallLogs）。
/// 界面在 Views/Chat/CallView.swift
@MainActor
@Observable
final class CallSession {
    enum Phase { case listening, thinking, speaking }

    struct Line: Identifiable, Codable, Hashable {
        var id = UUID()
        var mine: Bool
        var zh: String
        var ko = ""
    }

    let persona: Persona
    let convo: Conversation
    let members: [Persona]
    private(set) var phase: Phase = .listening
    private(set) var lines: [Line] = []
    /// 你正在说、还没说完的话
    private(set) var live = ""
    /// TA 正在念的那一句念到了百分之几（字幕一个字一个字亮起来）
    private(set) var spoken: Double = 0
    private(set) var muted = false
    private(set) var speaker = true

    func toggleMute() {
        muted.toggle()
        if muted { stopListening() } else if phase == .listening { listen() }
    }

    func toggleSpeaker() {
        speaker.toggle()
        route()
    }
    let started = Date()

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let relay: RelayClient
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silence: Task<Void, Never>?
    @ObservationIgnored private var replying: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ended = false
    /// 接话声：你说完、TA 还没想好第一句时，先「嗯……」一声，不冷场（通话开始时用 TA 的声音提前念好）
    @ObservationIgnored private var fillers: [Data] = []
    @ObservationIgnored private var fillerIndex = 0
    @ObservationIgnored private var filling: Task<Void, Never>?
    @ObservationIgnored private var fillerPlayer: AVAudioPlayer?
    @ObservationIgnored private var fillerPlaying = false

    init(persona: Persona, convo: Conversation, members: [Persona], context: ModelContext, relay: RelayClient) {
        self.persona = persona
        self.convo = convo
        self.members = members
        self.context = context
        self.relay = relay
    }

    /// 返回错误提示；成功时返回 nil
    func begin() async -> String? {
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard speech == .authorized else { return String(localized: "需要在系统设置里允许「语音识别」。") }
        guard await AVAudioApplication.requestRecordPermission() else { return String(localized: "需要在系统设置里允许使用麦克风。") }
        guard recognizer?.isAvailable == true else { return String(localized: "语音识别暂时不可用。") }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
        route()
        listen()
        prepareFillers()
        return nil
    }

    private func prepareFillers() {
        let phrases = persona.lang == .ko ? ["음…", "음, 잠깐만."] : ["嗯……", "嗯，我想想。"]
        let spec = VoiceSpec(persona)
        Task { [weak self] in
            for phrase in phrases {
                guard let audio = try? await Voice.speak(phrase, spec: spec) else { continue }
                self?.fillers.append(audio)
            }
        }
    }

    /// 等了一会儿第一句还没好：放一声接话（不进字幕和通话记录）
    private func playFiller() async {
        guard !fillers.isEmpty, !ended, let p = try? AVAudioPlayer(data: fillers[fillerIndex % fillers.count]) else { return }
        fillerIndex += 1
        fillerPlaying = true
        defer { fillerPlaying = false }
        fillerPlayer = p
        p.play()
        while p.isPlaying, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func route() {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none)
    }

    // MARK: - 听

    private func listen() {
        guard !ended else { return }
        phase = .listening
        live = ""
        guard !muted, let recognizer else { return }
        stopListening()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
        engine.prepare()
        try? engine.start()
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in self?.heard(text) }
        }
    }

    private func heard(_ text: String) {
        guard phase == .listening else { return }
        live = text
        // 停顿 1.2 秒就算说完了
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.finishUtterance()
        }
    }

    private func stopListening() {
        silence?.cancel()
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func finishUtterance() {
        let text = live.trimmed
        stopListening()
        guard !text.isEmpty else { return listen() }
        lines.append(Line(mine: true, zh: text))
        live = ""
        respond()
    }

    // MARK: - TA 说

    /// 这一轮发给 TA 的请求：最近的聊天 + 通话到现在说的话，用这个对话的整份人设
    private func turnRequest() -> RelayRequest {
        let names = Dictionary(members.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let call = lines.map { "\($0.mine ? PromptParts.userName : persona.name)：\($0.zh)" }.joined(separator: "\n")
        let prompt = """
        \(PromptParts.contextBlock(memory: nil, history: convo.visibleMessages(), recent: Limits.Prompt.callChat, names: names))

        你们现在正在打语音电话，通话到现在：
        \(call)

        现在轮到你说。像打电话那样：口语、自然，一次一两句，可以带「嗯」「哈哈」这类语气；不要用表情、不要写任何【】标记、不要用 Markdown。只输出你要说的话。
        """
        return PromptParts.lightRequest(persona, prompt, system: PromptBuilder.system(for: persona, convo: convo, members: members))
    }

    private func respond() {
        phase = .thinking
        let request = turnRequest()
        let queue = SentenceQueue(spec: VoiceSpec(persona))
        filling?.cancel()
        filling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await self?.playFiller()
        }
        replying = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in self.relay.run(request) {
                    guard !Task.isCancelled else { return }
                    if case .text(let t) = event {
                        queue.append(t)
                        // 第一句来了：还没开始的接话声就不放了（已经在放的放完）
                        if !queue.isEmpty && !self.fillerPlaying { self.filling?.cancel() }
                        if queue.hasReady { await queue.playReady { await self.say($0, audio: $1) } }
                    }
                }
                queue.finish()
                await queue.playReady { await self.say($0, audio: $1) }
            } catch {
                if queue.isEmpty { await self.say(String(localized: "喂？信号不太好，你再说一遍？"), audio: nil) }
            }
            guard !Task.isCancelled else { return }
            self.listen()
        }
    }

    /// 念一句：字幕先出来，跟着声音一个字一个字亮起来；念完把这句并进 TA 的那一行
    private func say(_ text: String, audio: Data?) async {
        // 接话声还没放完：等它放完再说，不叠在一起
        while fillerPlaying, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(40)) }
        filling?.cancel()
        phase = .speaking
        if let last = lines.last, !last.mine {
            lines[lines.count - 1].zh += text
            lines[lines.count - 1].ko = ""
        } else {
            lines.append(Line(mine: false, zh: text))
        }
        spoken = 0
        guard let audio, let p = try? AVAudioPlayer(data: audio) else {
            spoken = 1
            try? await Task.sleep(for: .milliseconds(400 + text.count * 120))
            return
        }
        player = p
        p.play()
        while p.isPlaying, !Task.isCancelled {
            spoken = p.duration > 0 ? p.currentTime / p.duration : 1
            try? await Task.sleep(for: .milliseconds(60))
        }
        spoken = 1
    }

    /// TA 说话时点头像：马上停下，听你说
    func interrupt() {
        guard phase != .listening else { return }
        replying?.cancel()
        filling?.cancel()
        player?.stop()
        fillerPlayer?.stop()
        listen()
    }

    // MARK: - 挂断

    func end() {
        guard !ended else { return }
        ended = true
        replying?.cancel()
        filling?.cancel()
        player?.stop()
        fillerPlayer?.stop()
        stopListening()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let seconds = Date.now.timeIntervalSince(started)
        guard !lines.isEmpty || seconds > 5 else { return }
        // 聊天里留一个「通话时长」气泡（你发起的，在你这边）；通话内容存在本机，点气泡能看
        let m = Message(role: .user, kind: .call, content: CallLogs.clock(seconds))
        m.readAt = .now
        convo.add(m, context: context)
        convo.updatedAt = .now
        context.persist()
        CallLogs.shared.set(lines, for: m.id)
    }

    func translated(_ id: UUID, _ ko: String) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[i].ko = ko
    }
}

/// 通话里 TA 一边想一边说：收到的字攒成一句一句，每句一到就先去合成（一边念这一句，一边合成下一句），再按顺序念出来。
/// 以前这些写在 respond 里的三个内嵌函数里、共用一堆局部变量（审查 Z-412）
@MainActor
final class SentenceQueue {
    /// 到这些字就算一句说完了
    private static let ends: Set<Character> = ["。", "！", "？", "!", "?", "…", "\n", "~"]

    private let spec: VoiceSpec
    /// 还没凑成一句的字
    private var buffer = ""
    /// 每一句的合成任务和文字，下标一一对应
    private var sentences: [Task<Data?, Never>] = []
    private var texts: [String] = []
    /// 已经念了几句
    private var played = 0

    init(spec: VoiceSpec) {
        self.spec = spec
    }

    /// 一句都还没有
    var isEmpty: Bool { texts.isEmpty }
    /// 有排好、还没念的句子
    var hasReady: Bool { played < sentences.count }

    /// 收到一段字：凑够一句就排上
    func append(_ text: String) {
        buffer += text
        cut(final: false)
    }

    /// 回复完了：剩下不成句的也排上
    func finish() {
        cut(final: true)
    }

    /// 按顺序把排好的句子念完；say 念一句（等合成好的声音，没有声音时只出字幕）
    func playReady(_ say: (String, Data?) async -> Void) async {
        while played < sentences.count {
            let audio = await sentences[played].value
            let text = texts[played]
            played += 1
            guard !Task.isCancelled else { return }
            await say(text, audio)
        }
    }

    private func cut(final: Bool) {
        while let i = buffer.firstIndex(where: { Self.ends.contains($0) }) {
            let s = String(buffer[...i]).trimmed
            buffer = String(buffer[buffer.index(after: i)...])
            if !s.isEmpty { queue(s) }
        }
        if final, !buffer.trimmed.isEmpty { queue(buffer.trimmed); buffer = "" }
    }

    private func queue(_ s: String) {
        let clean = ReplyText.markers(in: s).body.trimmed
        guard !clean.isEmpty else { return }
        texts.append(clean)
        let spec = spec
        sentences.append(Task { try? await Voice.speak(clean, spec: spec) })
    }
}
