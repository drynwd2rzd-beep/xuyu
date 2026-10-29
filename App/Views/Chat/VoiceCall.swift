import SwiftUI
import SwiftData
import Speech
import AVFoundation
import Translation
import Observation

/// 语音通话：你说话 → 停顿一下自动发出 → TA 一边想一边用自己的声音一句一句念出来，字幕下面带韩语翻译。
/// TA 说话时点中间的头像可以打断。挂断后聊天里留一个「通话时长」气泡，点开看通话内容（见 CallLogs）
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
        let phrases = persona.language == "ko" ? ["음…", "음, 잠깐만."] : ["嗯……", "嗯，我想想。"]
        let persona = self.persona
        Task { [weak self] in
            for phrase in phrases {
                guard let audio = try? await Voice.speak(phrase, for: persona) else { continue }
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

    private func respond() {
        phase = .thinking
        let names = Dictionary(members.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let recent = PromptBuilder.transcript(Array(convo.visibleMessages().suffix(12)), names: names)
        let call = lines.map { "\($0.mine ? PromptBuilder.userName : persona.name)：\($0.zh)" }.joined(separator: "\n")
        let prompt = """
        之前的聊天记录：
        \(recent.isEmpty ? "（还没有）" : recent)

        你们现在正在打语音电话，通话到现在：
        \(call)

        现在轮到你说。像打电话那样：口语、自然，一次一两句，可以带「嗯」「哈哈」这类语气；不要用表情、不要写任何【】标记、不要用 Markdown。只输出你要说的话。
        """
        let request = RelayRequest(engine: persona.engine.rawValue, model: PromptBuilder.model(for: persona), effort: "low",
                                   system: PromptBuilder.system(for: persona, convo: convo, members: members), prompt: prompt)
        filling?.cancel()
        filling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await self?.playFiller()
        }
        replying = Task { [weak self] in
            guard let self else { return }
            var buffer = ""
            var sentences: [Task<Data?, Never>] = []
            var texts: [String] = []
            let ends: Set<Character> = ["。", "！", "？", "!", "?", "…", "\n", "~"]
            func cut(final: Bool) {
                while let i = buffer.firstIndex(where: { ends.contains($0) }) {
                    let s = String(buffer[...i]).trimmed
                    buffer = String(buffer[buffer.index(after: i)...])
                    if !s.isEmpty { queue(s) }
                }
                if final, !buffer.trimmed.isEmpty { queue(buffer.trimmed); buffer = "" }
            }
            func queue(_ s: String) {
                let clean = ReplyText.markers(in: s).body.trimmed
                guard !clean.isEmpty else { return }
                texts.append(clean)
                let persona = self.persona
                // 一边念这一句，一边先合成下一句：不用等
                sentences.append(Task { try? await Voice.speak(clean, for: persona) })
            }
            var played = 0
            func playReady() async {
                while played < sentences.count {
                    let audio = await sentences[played].value
                    let text = texts[played]
                    played += 1
                    guard !Task.isCancelled else { return }
                    await self.say(text, audio: audio)
                }
            }
            do {
                for try await event in self.relay.run(request) {
                    guard !Task.isCancelled else { return }
                    if case .text(let t) = event {
                        buffer += t
                        cut(final: false)
                        // 第一句来了：还没开始的接话声就不放了（已经在放的放完）
                        if !texts.isEmpty && !self.fillerPlaying { self.filling?.cancel() }
                        if played < sentences.count { await playReady() }
                    }
                }
                cut(final: true)
                await playReady()
            } catch {
                if texts.isEmpty { await self.say(String(localized: "喂？信号不太好，你再说一遍？"), audio: nil) }
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

/// 通话内容：消息 ID → 每一句（中文 + 韩语），存在本机一个小文件里
@Observable
final class CallLogs {
    static let shared = CallLogs()
    private(set) var byMessage: [UUID: [CallSession.Line]] = [:]
    @ObservationIgnored private let file: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        file = dir.appendingPathComponent("calls.json")
        reload()
    }

    /// 从文件读（打开时、从备份恢复后）
    func reload() {
        byMessage = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([UUID: [CallSession.Line]].self, from: $0) } ?? [:]
    }

    func lines(_ id: UUID) -> [CallSession.Line] { byMessage[id] ?? [] }

    func set(_ lines: [CallSession.Line], for id: UUID) {
        byMessage[id] = lines
        if let data = try? JSONEncoder().encode(byMessage) { try? data.write(to: file, options: .atomic) }
    }

    func clear() {
        byMessage = [:]
        try? FileManager.default.removeItem(at: file)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// 打电话的入口：通话记录里点「再打一次」时用
    static let callAgain = Notification.Name("xuyu.callAgain")
}

/// 通话页：深色、头像在中间，光晕跟着谁在说话变；字幕下面是韩语
struct CallView: View {
    @State var session: CallSession
    @Environment(\.dismiss) private var dismiss
    @State private var korean = true
    @State private var failure: String?
    @State private var translation: TranslationSession.Configuration?
    @State private var tick = Date.now

    private let night = Color(hex: 0x121212)
    private let glow = Color(hex: 0xD97757)
    private let light = Color(hex: 0xF4F3EF)

    var body: some View {
        ZStack {
            night.ignoresSafeArea()
            RadialGradient(colors: [glow.opacity(glowStrength), glow.opacity(glowStrength * 0.35), .clear],
                           center: UnitPoint(x: 0.5, y: 0.34), startRadius: 10, endRadius: 360)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.8), value: session.phase)
            LinearGradient(colors: [.black.opacity(0.38), .clear], startPoint: .bottom, endPoint: .center).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button { minimize() } label: {
                        Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold)).foregroundStyle(light.opacity(0.8))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("收起通话")
                    Spacer()
                    Button { withAnimation(Motion.snappy) { korean.toggle() } } label: {
                        Text("한").font(.system(size: 14, weight: .medium))
                            .foregroundStyle(korean ? night : light)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(korean ? light : light.opacity(0.12), in: Capsule())
                    }
                    .accessibilityLabel(korean ? Text("韩语字幕（开）") : Text("韩语字幕（关）"))
                }
                .padding(.horizontal, Space.tight)

                VStack(spacing: 4) {
                    Text(session.persona.name).font(Typo.display(32)).tracking(-0.4).foregroundStyle(light)
                    Text("\(status) · \(CallLogs.clock(tick.timeIntervalSince(session.started)))")
                        .font(Typo.serif(14.5).italic()).foregroundStyle(light.opacity(0.55))
                        .contentTransition(.opacity)
                }
                .padding(.top, 8)

                Button { session.interrupt() } label: { orb }
                    .buttonStyle(.plain)
                    .accessibilityLabel(session.phase == .listening ? Text("TA 在听") : Text("打断 TA"))
                    .padding(.top, 36)

                captions
                    .padding(.horizontal, 34)
                    .padding(.top, 32)

                Spacer()

                HStack(spacing: 38) {
                    control(session.speaker ? "speaker.wave.2.fill" : "speaker.fill", "speaker", on: session.speaker) { session.toggleSpeaker() }
                    control(session.muted ? "mic.slash.fill" : "mic.fill", "mute", on: session.muted) { session.toggleMute() }
                    VStack(spacing: 8) {
                        Button { hangUp() } label: {
                            Image(systemName: "phone.down.fill").font(.system(size: 24)).foregroundStyle(.white)
                                .frame(width: 72, height: 72)
                                .background(Color(hex: 0xC4554B), in: Circle())
                        }
                        .accessibilityLabel("挂断")
                        Text("end").font(Typo.serif(13).italic()).foregroundStyle(light.opacity(0.6))
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if let error = await session.begin() { failure = error }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick = .now
            }
        }
        // 韩语字幕：iPhone 自带的翻译（不花钱）。有新的一句没翻就翻
        .onChange(of: session.lines.map(\.zh)) { _, _ in
            if translation == nil {
                translation = TranslationSession.Configuration(source: Locale.Language(identifier: "zh-Hans"), target: Locale.Language(identifier: "ko"))
            } else {
                translation?.invalidate()
            }
        }
        .translationTask(translation) { t in
            for line in session.lines where line.ko.isEmpty {
                if let r = try? await t.translate(line.zh) { session.translated(line.id, r.targetText) }
            }
        }
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil; dismiss() } })) {
            Button("好", role: .cancel) {}
        }
        .onDisappear { session.end() }
    }

    private var status: String {
        switch session.phase {
        case .listening: session.muted ? "muted" : "listening"
        case .thinking: "thinking"
        case .speaking: "speaking"
        }
    }

    private var glowStrength: Double {
        switch session.phase {
        case .speaking: 0.30
        case .listening: 0.18
        case .thinking: 0.10
        }
    }

    private var orb: some View {
        let speaking = session.phase == .speaking
        return ZStack {
            if speaking {
                Circle().fill(glow.opacity(0.06)).frame(width: 232, height: 232)
                Circle().fill(glow.opacity(0.09)).frame(width: 194, height: 194)
            } else if session.phase == .listening {
                Circle().strokeBorder(light.opacity(0.16), lineWidth: 1).frame(width: 178, height: 178)
            }
            AvatarView(persona: session.persona, size: speaking ? 156 : session.phase == .thinking ? 140 : 150)
                .overlay {
                    Circle().fill(RadialGradient(colors: [.white.opacity(0.16), .clear], center: UnitPoint(x: 0.32, y: 0.24), startRadius: 0, endRadius: 60))
                }
                .shadow(color: .black.opacity(0.5), radius: 30, y: 24)
                .shadow(color: glow.opacity(speaking ? 0.3 : 0.12), radius: 40)
                .opacity(session.phase == .thinking ? 0.8 : 1)
        }
        .frame(height: 240)
        .animation(.spring(duration: 0.6, bounce: 0.1), value: session.phase)
    }

    @ViewBuilder
    private var captions: some View {
        let lines = session.lines.suffix(2)
        VStack(spacing: 20) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                let current = index == lines.count - 1 && session.live.isEmpty
                VStack(spacing: 5) {
                    Text(line.mine ? "you" : session.persona.name)
                        .font(Typo.serif(12.5).italic()).foregroundStyle(light.opacity(current ? 0.5 : 0.3))
                    if current && !line.mine && session.phase == .speaking {
                        karaoke(line.zh)
                    } else {
                        Text(line.zh)
                            .font(Typo.serif(current ? 22 : 15.5))
                            .foregroundStyle(light.opacity(current ? 1 : 0.34))
                    }
                    if korean, !line.ko.isEmpty {
                        Text(line.ko).font(.system(size: current ? 14.5 : 12.5, weight: .light)).foregroundStyle(light.opacity(current ? 0.6 : 0.26))
                    }
                }
                .multilineTextAlignment(.center)
                .transition(.opacity.combined(with: .offset(y: 10)))
            }
            if !session.live.isEmpty {
                VStack(spacing: 5) {
                    Text("you").font(Typo.serif(12.5).italic()).foregroundStyle(light.opacity(0.5))
                    Text(session.live).font(Typo.serif(22)).foregroundStyle(light).multilineTextAlignment(.center)
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.spring, value: session.lines.count)
    }

    /// TA 正在念的那句：念到的字亮，没念到的暗
    private func karaoke(_ text: String) -> some View {
        let count = Int((Double(text.count) * session.spoken).rounded())
        let said = String(text.prefix(count)), rest = String(text.dropFirst(count))
        return (Text(said).foregroundStyle(light) + Text(rest).foregroundStyle(light.opacity(0.38)))
            .font(Typo.serif(22))
    }

    private func control(_ symbol: String, _ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 21)).foregroundStyle(on ? night : light)
                    .frame(width: 72, height: 72)
                    .background(on ? light : light.opacity(0.10), in: Circle())
                    .overlay(Circle().strokeBorder(light.opacity(0.18), lineWidth: 0.5))
            }
            .accessibilityLabel(label == "speaker" ? Text("扬声器") : Text("静音"))
            Text(label).font(Typo.serif(13).italic()).foregroundStyle(light.opacity(0.6))
        }
    }

    private func minimize() {
        // 收起就是挂断（通话不在后台继续）
        hangUp()
    }

    private func hangUp() {
        session.end()
        dismiss()
    }
}

/// 聊天里的「通话时长」气泡，点开看通话内容和「再打一次」
struct CallBubble: View {
    let message: Message
    let isUser: Bool
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: Space.tight) {
                Image(systemName: "phone").font(.system(size: 14))
                Text("通话时长 \(message.content)").font(.system(size: Typo.body))
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isUser ? Palette.fill : Palette.card, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $open) {
            CallLogSheet(message: message)
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
    }
}

struct CallLogSheet: View {
    let message: Message
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let lines = CallLogs.shared.lines(message.id)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Voice call").font(Typo.display(26)).foregroundStyle(Palette.ink)
                    Spacer()
                    Text("\(message.content) · \(Fmt.hm.string(from: message.createdAt))").font(Typo.serif(14).italic()).foregroundStyle(Palette.inkSoft)
                }
                .padding(.top, 24)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        if index > 0 { Hairline() }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.mine ? "you" : (message.conversation?.title.isEmpty == false ? message.conversation!.title : "TA"))
                                .font(Typo.serif(12.5).italic()).foregroundStyle(Palette.inkSoft)
                            Text(line.zh).font(.system(size: 15)).foregroundStyle(Palette.ink)
                            if !line.ko.isEmpty { Text(line.ko).font(.system(size: 13)).foregroundStyle(Palette.inkSoft) }
                        }
                        .padding(.horizontal, Space.card)
                        .padding(.vertical, 11)
                    }
                    if lines.isEmpty {
                        Text("这通电话没有留下文字。").font(.system(size: 14)).foregroundStyle(Palette.inkSoft).padding(Space.card)
                    }
                }
                .card()
                Button {
                    dismiss()
                    if let id = message.conversation?.id { NotificationCenter.default.post(name: CallLogs.callAgain, object: id) }
                } label: {
                    Label("再打一次", systemImage: "phone").font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Palette.inkInverse)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(Palette.ink, in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, 30)
        }
    }
}
