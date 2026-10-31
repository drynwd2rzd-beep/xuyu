import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 设置 › 语音：填 ElevenLabs、MiniMax 的密钥（只存在这台手机的钥匙串里）。
/// 用哪家、哪个模型、哪个声音，在每个角色页里单独选
struct VoiceSettingsView: View {
    var body: some View {
        SettingsPage(title: "语音") {
            VoiceKeyGroup(provider: .elevenlabs)
            VoiceKeyGroup(provider: .minimax)
        }
    }
}

/// 一家语音服务的密钥：没填时粘贴，填了显示连接状态
private struct VoiceKeyGroup: View {
    let provider: VoiceProvider
    @State private var key = ""
    @State private var configured = false
    @State private var status: String?
    @AppStorage(Prefs.minimaxRegion) private var region = MiniMaxRegion.cn.rawValue

    var body: some View {
        SettingsGroup(title: provider.label) {
            if provider == .minimax {
                SettingRow(title: "平台") {
                    Segmented(items: [(MiniMaxRegion.cn.rawValue, "国内版"), (MiniMaxRegion.global.rawValue, "国际版")], selection: $region)
                        .fixedSize()
                }
                Hairline()
            }
            if configured {
                SettingRow(title: "密钥", subtitle: status) {
                    Button("移除") {
                        Voice.setKey("", for: provider)
                        withAnimation(Motion.spring) { configured = false }
                        status = nil
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.danger)
                }
            } else {
                HStack(spacing: Space.tight) {
                    SecureField("粘贴 API 密钥", text: $key)
                        .font(.system(size: 15))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(save)
                    Button("保存", action: save)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(key.trimmed.isEmpty ? Palette.faint : Palette.ink)
                        .disabled(key.trimmed.isEmpty)
                }
                .padding(.horizontal, Space.card)
                .frame(minHeight: Space.row)
            }
            Hairline()
            // 打开这家的充值页面（在 Safari 里登录、充值、看余额）
            Link(destination: provider.topUpURL) {
                SettingRow(title: "充值与余额") {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                }
            }
            .buttonStyle(PressableRowStyle())
        }
        .onAppear { configured = Voice.isConfigured(provider) }
        .task(id: "\(configured)-\(region)") { await check() }
    }

    private func save() {
        guard !key.trimmed.isEmpty else { return }
        Voice.setKey(key, for: provider)
        key = ""
        withAnimation(Motion.spring) { configured = true }
    }

    private func check() async {
        guard configured else { return }
        status = String(localized: "正在连接…")
        do {
            let voices = try await Voice.voices(provider)
            status = String(localized: "已连接 · \(voices.count) 个声音")
        } catch {
            status = error.localizedDescription
        }
    }
}

/// 语音相关的弹出页：标题、关闭或完成、纸色背景
private struct VoiceSheet<Content: View>: View {
    let title: String
    var done = false
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) { content }
                    .padding(Space.page)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle(LocalizedStringKey(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: done ? .confirmationAction : .cancellationAction) {
                    Button { dismiss() } label: {
                        Text(LocalizedStringKey(done ? "完成" : "关闭")).fontWeight(done ? .semibold : .regular)
                    }
                }
            }
        }
    }
}

/// 设置组里的一行输入框
private struct FieldRow: View {
    let placeholder: String
    @Binding var text: String
    var multiline = false

    var body: some View {
        TextField(LocalizedStringKey(placeholder), text: $text, axis: multiline ? .vertical : .horizontal)
            .font(.system(size: 15))
            .lineLimit(multiline ? 2...8 : 1...1)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, Space.card)
            .padding(.vertical, 12)
            .frame(minHeight: Space.row)
    }
}

// MARK: - 选择声音

/// 给角色挑一个声音：上面是自己复刻的（可以改名、删除），下面是这家的全部声音，右边可以先试听。
/// onPick 不为空时只是挑一个声音（混合声音用），不改角色
struct VoicePicker: View {
    @Bindable var persona: Persona
    var onPick: ((Voice.Choice) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var service: VoiceProvider = .elevenlabs
    @State private var voices: [Voice.Choice] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var notice: String?
    @State private var query = ""
    @State private var customID = ""
    @State private var cloning = false
    @State private var renaming: Voice.Choice?
    @State private var newName = ""
    @State private var deleting: Voice.Choice?
    @State private var loadingPreview: String?
    @State private var previews: [String: Data] = [:]
    /// 试听没成功的原因
    @State private var previewFailure: String?

    init(persona: Persona, onPick: ((Voice.Choice) -> Void)? = nil) {
        _persona = Bindable(persona)
        self.onPick = onPick
        _service = State(initialValue: Voice.provider(of: persona))
    }

    private var player: VoicePlayer { VoicePlayer.shared }
    private var picking: Bool { onPick != nil }

    /// 声音很多：可以搜名字和描述
    private func filtered(_ list: [Voice.Choice]) -> [Voice.Choice] {
        let q = query.trimmed
        guard !q.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.detail.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let mine = filtered(voices.filter(\.mine))
        let others = filtered(voices.filter { !$0.mine })
        VoiceSheet(title: picking ? "添加声音" : "选择声音") {
            if !picking && Voice.configured.count > 1 {
                Segmented(items: Voice.configured.map { ($0, $0.label) }, selection: $service)
                    .frame(maxWidth: .infinity)
            }
            if voices.count > 12 {
                SearchField(text: $query, placeholder: "搜索")
            }
            if !picking || !mine.isEmpty {
                SettingsGroup(title: "我的声音") {
                    if !picking {
                        Button { cloning = true } label: {
                            SettingRow(title: "复刻新声音") {
                                Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                            }
                        }
                        .buttonStyle(PressableRowStyle())
                    }
                    ForEach(Array(mine.enumerated()), id: \.element.id) { index, v in
                        if index > 0 || !picking { Hairline() }
                        row(v)
                    }
                }
                if let notice {
                    Text(LocalizedStringKey(notice)).font(.system(size: 13)).foregroundStyle(Palette.inkSoft).padding(.horizontal, 6)
                }
            }
            if !picking {
                // 在官网复刻、还没用过的声音不在列表里：直接填它的 ID 也能马上用
                HStack(spacing: Space.tight) {
                    TextField("填写声音 ID", text: $customID)
                        .font(.system(size: 15))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(useCustomID)
                    Button("使用", action: useCustomID)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(customID.trimmed.isEmpty ? Palette.faint : Palette.ink)
                        .disabled(customID.trimmed.isEmpty)
                }
                .padding(.horizontal, Space.card)
                .frame(minHeight: Space.row)
                .card()
            }
            SettingsGroup(title: "全部声音") {
                if let failure {
                    Text(failure).font(.system(size: 14)).foregroundStyle(Palette.inkSoft).padding(Space.card)
                } else if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(Space.section)
                }
                ForEach(Array(others.enumerated()), id: \.element.id) { index, v in
                    if index > 0 { Hairline() }
                    row(v)
                }
            }
        }
        .task(id: service) { await load() }
        .onDisappear { player.stop() }
        .sheet(isPresented: $cloning) {
            VoiceCloneSheet(provider: service, persona: persona) {
                Task { await load() }
            }
        }
        .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { v in
            TextField("名字", text: $newName)
            Button("保存") { rename(v) }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(Text("删除「\(deleting?.name ?? "")」？"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { v in
            Button("删除", role: .destructive) { delete(v) }
        } message: { _ in
            Text("删除后找不回来，用这个声音的角色也会没有声音。")
        }
        .alert("没能试听", isPresented: Binding(get: { previewFailure != nil }, set: { if !$0 { previewFailure = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(previewFailure ?? "")
        }
    }

    private func load() async {
        loaded = false
        failure = nil
        do {
            let list = try await Voice.voices(service)
            withAnimation(Motion.spring) { voices = list }
        } catch {
            voices = []
            failure = error.localizedDescription
        }
        loaded = true
    }

    private func row(_ v: Voice.Choice) -> some View {
        Button {
            if let onPick {
                onPick(v)
                dismiss()
            } else {
                choose(id: v.id, name: v.name)
            }
        } label: {
            HStack(spacing: Space.item) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.name).font(.system(size: 15)).foregroundStyle(Palette.ink).lineLimit(1)
                    if !v.detail.isEmpty {
                        Text(v.detail).font(.system(size: 12)).foregroundStyle(Palette.inkSoft).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if !picking && persona.voiceID == v.id {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                }
                previewButton(v)
            }
            .padding(.horizontal, Space.card)
            .frame(minHeight: Space.row + 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .contextMenu {
            if v.mine && !picking {
                Button { newName = v.name; renaming = v } label: { Label("重命名", systemImage: "pencil") }
                Button(role: .destructive) { deleting = v } label: { Label("删除", systemImage: "trash") }
            }
        }
    }

    /// 换成这个声音；换了服务就把模型和混合声音清掉（两家不通用）
    private func choose(id: String, name: String) {
        if persona.provider != service {
            persona.provider = service
            persona.voiceModel = ""
            persona.style.mixes = []
        }
        persona.voiceID = id
        persona.voiceName = name
        if persona.voiceFreq == 0 { persona.voiceFreq = 1 }
        dismiss()
    }

    /// 用填进来的声音 ID（名字先显示 ID，之后可以改）
    private func useCustomID() {
        let id = customID.trimmed
        guard !id.isEmpty else { return }
        choose(id: id, name: VoiceNames.all[id] ?? id)
    }

    /// 改名：所有用这个声音的角色一起改
    private func rename(_ v: Voice.Choice) {
        let name = newName.trimmed
        guard !name.isEmpty else { return }
        Task {
            do {
                try await Voice.rename(v, to: name, on: service)
                for p in users(of: v.id) { p.voiceName = name }
                notice = nil
                await load()
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// 删除：用这个声音的角色变回没有声音
    private func delete(_ v: Voice.Choice) {
        Task {
            do {
                try await Voice.delete(v, on: service)
                for p in users(of: v.id) {
                    p.voiceID = ""
                    p.voiceName = ""
                }
                notice = nil
                await load()
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    private func users(of voiceID: String) -> [Persona] {
        ((try? context.fetch(FetchDescriptor<Persona>())) ?? []).filter { $0.voiceID == voiceID }
    }

    /// 试听：ElevenLabs 下载自带的样音；没有样音的用这个声音现念一句（会用一点点额度）
    private func previewButton(_ v: Voice.Choice) -> some View {
        Button {
            if let data = previews[v.id] {
                if !player.toggle(v.id, data: data) { previewFailure = String(localized: "这段声音放不出来。") }
                return
            }
            loadingPreview = v.id
            Task {
                defer { loadingPreview = nil }
                do {
                    let data: Data
                    if let url = v.preview {
                        data = try await URLSession.shared.data(from: url).0
                    } else {
                        let sample = Persona(name: "")
                        sample.provider = service
                        sample.voiceModel = persona.provider == service ? persona.voiceModel : ""
                        sample.voiceID = v.id
                        sample.language = persona.language
                        data = try await Voice.speak(persona.lang == .ko ? "안녕, 오늘 하루 어땠어?" : "你好呀，今天过得怎么样？", for: sample)
                    }
                    // 放不出来的不留着，下次点还会重新取
                    guard player.toggle(v.id, data: data) else {
                        previewFailure = String(localized: "这段声音放不出来。")
                        return
                    }
                    previews[v.id] = data
                } catch {
                    // 以前失败了转一下圈就没了，什么也不说
                    previewFailure = error.localizedDescription
                }
            }
        } label: {
            Group {
                if loadingPreview == v.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: player.playing == v.id ? "stop.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(Palette.ink)
            .frame(width: 32, height: 32)
            .background(Palette.fill, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("试听")
    }
}

// MARK: - 复刻

/// 复刻新声音：起名字、选一段或几段录音（视频也行，自动取出声音、接成一段、压缩），官网能填的选项都在这里。
/// 复刻好后换成这个声音，用它念一句试听
struct VoiceCloneSheet: View {
    let provider: VoiceProvider
    @Bindable var persona: Persona
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var clips: [Clip] = []
    @State private var reference: Clip?
    @State private var referenceText = ""
    @State private var importing: Target?
    @State private var denoise = true
    @State private var normalize = true
    @State private var languageBoost = ""
    @State private var validation = ""
    @State private var accuracy = 0.7
    @State private var detail = ""
    @State private var sample = ""
    @State private var working: String?
    @State private var failure: String?
    @State private var confirming = false

    struct Clip: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let seconds: Double
    }

    enum Target { case clips, reference }

    private var total: Double { clips.reduce(0) { $0 + $1.seconds } }
    // 压缩后会短零点几秒：留一点余量，卡在 10 秒正好会被 MiniMax 当成太短（2037）
    private var ready: Bool { !name.trimmed.isEmpty && total >= 10.5 && working == nil }
    private var defaultSample: String {
        persona.lang == .ko ? "안녕, 이제 이 목소리로 말할게." : "你好呀，以后我就用这个声音跟你说话啦。"
    }

    var body: some View {
        VoiceSheet(title: "复刻新声音") {
            SettingsGroup(title: "名字") {
                FieldRow(placeholder: "给这个声音起个名字", text: $name)
            }

            // 录音：10 秒到 5 分钟，只有一个人说话；几段会按顺序接起来
            SettingsGroup(title: "录音") {
                ForEach(clips) { clip in
                    SettingRow(title: clip.name) {
                        Text(Self.time(clip.seconds)).font(.system(size: 14).monospacedDigit()).foregroundStyle(Palette.inkSoft)
                        Button {
                            withAnimation(Motion.spring) { clips.removeAll { $0.id == clip.id } }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.faint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除")
                    }
                    Hairline()
                }
                Button { importing = .clips } label: {
                    SettingRow(title: "添加录音或视频") {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    }
                }
                .buttonStyle(PressableRowStyle())
                if !clips.isEmpty {
                    Hairline()
                    SettingRow(title: "合计", subtitle: total > AudioMerge.cloneLimit ? "超过 4 分 50 秒的部分不会用" : total < 10.5 ? "至少要 10 秒" : nil) {
                        Text(Self.time(total)).font(.system(size: 14).monospacedDigit()).foregroundStyle(Palette.inkSoft)
                    }
                }
            }

            if provider == .minimax {
                // 参考录音：8 秒以内的一小段和它说的原话，让声音更像、更稳（选填）
                SettingsGroup(title: "参考录音") {
                    Button { importing = .reference } label: {
                        SettingRow(title: reference?.name ?? String(localized: "选一段 8 秒以内的录音")) {
                            if let reference {
                                Text(Self.time(min(reference.seconds, AudioMerge.referenceLimit)))
                                    .font(.system(size: 14).monospacedDigit()).foregroundStyle(Palette.inkSoft)
                            }
                            Chevron()
                        }
                    }
                    .buttonStyle(PressableRowStyle())
                    if reference != nil {
                        Hairline()
                        FieldRow(placeholder: "这段录音说的原话", text: $referenceText, multiline: true)
                    }
                }
            }

            SettingsGroup(title: "选项") {
                SettingRow(title: provider == .minimax ? "降噪" : "去除背景噪音") { InkToggle(isOn: $denoise, label: "降噪") }
                if provider == .minimax {
                    Hairline()
                    SettingRow(title: "音量统一") { InkToggle(isOn: $normalize, label: "音量统一") }
                    Hairline()
                    SettingRow(title: "语言增强") {
                        Menu {
                            ForEach(VoiceStyle.languages.dropFirst(), id: \.0) { item in
                                Button(LocalizedStringKey(item.1)) { languageBoost = item.0 }
                            }
                            Button("不设置") { languageBoost = "" }
                        } label: {
                            MenuValue(text: languageBoost.isEmpty ? "不设置" : VoiceStyle.languages.first { $0.0 == languageBoost }?.1 ?? languageBoost)
                        }
                    }
                    Hairline()
                    FieldRow(placeholder: "录音里说的原话（用来核对，选填）", text: $validation, multiline: true)
                    if !validation.trimmed.isEmpty {
                        Hairline()
                        VoiceSlider(title: "核对严格度", value: $accuracy, range: 0.1...1, step: 0.05,
                                    label: "\(Int((accuracy * 100).rounded()))%")
                    }
                } else {
                    Hairline()
                    FieldRow(placeholder: "描述这个声音（选填）", text: $detail, multiline: true)
                }
            }

            SettingsGroup(title: "试听") {
                FieldRow(placeholder: defaultSample, text: $sample, multiline: true)
            }

            Button {
                if provider == .minimax { confirming = true } else { clone() }
            } label: {
                HStack(spacing: 8) {
                    if working != nil { ProgressView().controlSize(.small).tint(Palette.inkInverse) }
                    Text(LocalizedStringKey(working ?? "复刻"))
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.inkInverse)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Palette.ink.opacity(ready || working != nil ? 1 : 0.35), in: Capsule())
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(!ready)

            if let failure {
                Text(failure).font(.system(size: 13)).foregroundStyle(Palette.danger).padding(.horizontal, 6)
            }
        }
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: [.audio, .movie], allowsMultipleSelection: importing == .clips) { result in
            let target = importing
            guard case .success(let urls) = result else { return }
            Task { await add(urls, to: target) }
        }
        .confirmationDialog("复刻这个声音？", isPresented: $confirming, titleVisibility: .visible) {
            Button("复刻并试听") { clone() }
        } message: {
            Text("复刻好后会马上用新声音念一句给你听：第一次使用时 MiniMax 会扣一次复刻费。")
        }
        .interactiveDismissDisabled(working != nil)
    }

    private func add(_ urls: [URL], to target: Target?) async {
        var added: [Clip] = []
        for url in urls {
            guard let copy = AudioMerge.copyIn(url) else { continue }
            let seconds = await AudioMerge.duration(copy)
            guard seconds > 0 else {
                failure = String(localized: "读不出这段录音")
                continue
            }
            added.append(Clip(url: copy, name: url.deletingPathExtension().lastPathComponent, seconds: seconds))
        }
        withAnimation(Motion.spring) {
            if target == .reference { reference = added.first ?? reference } else { clips += added }
            // 没起名字：先用第一段录音的文件名
            if name.trimmed.isEmpty, target == .clips, let first = added.first { name = first.name }
        }
    }

    private func clone() {
        failure = nil
        working = "正在整理录音…"
        Task {
            do {
                let audio = try await AudioMerge.merge(clips.map(\.url), limit: AudioMerge.cloneLimit)
                var request = Voice.CloneRequest(name: name.trimmed, audio: audio)
                if provider == .minimax, let reference, !referenceText.trimmed.isEmpty {
                    request.reference = try await AudioMerge.merge([reference.url], limit: AudioMerge.referenceLimit)
                    request.referenceText = referenceText
                }
                request.denoise = denoise
                request.normalize = normalize
                request.languageBoost = languageBoost
                request.validation = validation
                request.accuracy = accuracy
                request.description = detail
                working = "正在复刻…"
                let id = try await Voice.clone(request, on: provider)
                // 换成新声音，用它念一句（MiniMax 这一句算第一次使用，声音就会一直保留）
                if persona.provider != provider {
                    persona.provider = provider
                    persona.voiceModel = ""
                    persona.style.mixes = []
                }
                persona.voiceID = id
                persona.voiceName = name.trimmed
                if persona.voiceFreq == 0 { persona.voiceFreq = 1 }
                onDone()
                working = "正在试听…"
                let data = try await Voice.speak(sample.trimmed.isEmpty ? defaultSample : sample.trimmed, for: persona)
                VoicePlayer.shared.toggle("clone-\(id)", data: data)
                working = nil
                dismiss()
            } catch {
                working = nil
                failure = error.localizedDescription
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - 声音调节

/// 滑杆一行：标题、数值，两头可以写上是什么方向
struct VoiceSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    var low: String? = nil
    var high: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(title)).font(.system(size: 16)).foregroundStyle(Palette.ink)
                Spacer()
                Text(label).font(.system(size: 14).monospacedDigit()).foregroundStyle(Palette.inkSoft)
            }
            Slider(value: $value, in: range, step: step) {
                Text(LocalizedStringKey(title))
            } minimumValueLabel: {
                if let low { Text(LocalizedStringKey(low)).font(.system(size: 12)).foregroundStyle(Palette.inkSoft) }
            } maximumValueLabel: {
                if let high { Text(LocalizedStringKey(high)).font(.system(size: 12)).foregroundStyle(Palette.inkSoft) }
            }
            .tint(Palette.ink)
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, Space.item)
    }
}

/// 声音调节：模型和官网能调的全部参数，调完马上试听。只显示这家服务支持的
struct VoiceTuneSheet: View {
    @Bindable var persona: Persona
    @State private var models: [Voice.ModelChoice] = []
    @State private var modelFailure: String?
    @State private var previewing = false
    @State private var failure: String?
    @State private var addingMix = false

    private var provider: VoiceProvider { Voice.provider(of: persona) }
    private var player: VoicePlayer { VoicePlayer.shared }
    private var model: String { persona.voiceModel.isEmpty ? provider.defaultModel : persona.voiceModel }

    /// 角色的其余声音设置，改哪项存哪项
    private var style: Binding<VoiceStyle> {
        Binding(get: { persona.style }, set: { persona.style = $0 })
    }

    /// 这个模型支持的情绪：耳语、平稳只有 2.6 模型能用
    private var emotions: [(String, String)] {
        Voice.emotions.filter { !["whisper", "fluent"].contains($0.0) || model.hasPrefix("speech-2.6") }
    }

    var body: some View {
        VoiceSheet(title: "声音调节", done: true) {
            modelGroup
            basicGroup
            if provider == .elevenlabs { elevenGroup }
            if provider == .minimax {
                toneGroup
                mixGroup
                readingGroup
            }
            HStack(spacing: Space.item) {
                Button("恢复默认", action: reset)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.inkSoft)
                Spacer()
                Button(action: preview) {
                    HStack(spacing: 6) {
                        if previewing { ProgressView().controlSize(.small).tint(Palette.inkInverse) }
                        Text("试听")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.inkInverse)
                    .padding(.horizontal, 22)
                    .frame(height: 40)
                    .background(Palette.ink, in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(previewing || persona.voiceID.isEmpty)
            }
            .padding(.horizontal, 6)
            if let failure {
                Text(failure).font(.system(size: 13)).foregroundStyle(Palette.inkSoft).padding(.horizontal, 6)
            }
        }
        .task {
            do { models = try await Voice.models(provider) } catch { modelFailure = error.localizedDescription }
        }
        .onDisappear { player.stop() }
        .sheet(isPresented: $addingMix) {
            VoicePicker(persona: persona) { v in
                guard v.id != persona.voiceID, !persona.style.mixes.contains(where: { $0.id == v.id }) else { return }
                withAnimation(Motion.spring) { persona.style.mixes.append(.init(id: v.id, name: v.name, weight: 50)) }
            }
        }
    }

    /// 模型：每个都写明侧重点
    private var modelGroup: some View {
        SettingsGroup(title: "模型") {
            if let modelFailure {
                Text(modelFailure).font(.system(size: 14)).foregroundStyle(Palette.inkSoft).padding(Space.card)
            } else if models.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(Space.card)
            }
            ForEach(Array(models.enumerated()), id: \.element.id) { index, m in
                if index > 0 { Hairline() }
                Button {
                    withAnimation(Motion.spring) {
                        persona.voiceModel = m.id == provider.defaultModel ? "" : m.id
                        // 换到不支持这种情绪的模型：情绪回到自动
                        if !emotions.contains(where: { $0.0 == persona.voiceEmotion }) { persona.voiceEmotion = "" }
                    }
                } label: {
                    SettingRow(title: m.name, subtitle: m.detail.isEmpty ? nil : m.detail) {
                        if model == m.id {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                        }
                    }
                }
                .buttonStyle(PressableRowStyle())
            }
        }
    }

    private var basicGroup: some View {
        SettingsGroup(title: "基础") {
            VoiceSlider(title: "语速", value: $persona.voiceSpeed,
                        range: provider == .minimax ? 0.5...2 : 0.7...1.2, step: 0.05,
                        label: String(format: "%.2g×", persona.voiceSpeed), low: "慢", high: "快")
            if provider == .minimax {
                Hairline()
                VoiceSlider(title: "音量", value: $persona.voiceVolume, range: 0.1...10, step: 0.1,
                            label: String(format: "%.1f", persona.voiceVolume), low: "轻", high: "响")
                Hairline()
                VoiceSlider(title: "音调", value: Self.whole($persona.voicePitch), range: -12...12, step: 1,
                            label: Self.signed(persona.voicePitch), low: "低", high: "高")
                Hairline()
                SettingRow(title: "情绪") {
                    Menu {
                        ForEach(emotions, id: \.0) { e in
                            Button { persona.voiceEmotion = e.0 } label: {
                                if persona.voiceEmotion == e.0 { Label(LocalizedStringKey(e.1), systemImage: "checkmark") } else { Text(LocalizedStringKey(e.1)) }
                            }
                        }
                    } label: {
                        MenuValue(text: Voice.emotions.first { $0.0 == persona.voiceEmotion }?.1 ?? "自动")
                    }
                }
            }
        }
    }

    /// ElevenLabs 的声音设置：稳定性、相似度、风格强度、说话人增强
    private var elevenGroup: some View {
        SettingsGroup(title: "表现") {
            VoiceSlider(title: "稳定性", value: style.stability, range: 0...1, step: 0.05,
                        label: Self.percent(persona.style.stability), low: "多变", high: "稳定")
            Hairline()
            VoiceSlider(title: "相似度", value: style.similarity, range: 0...1, step: 0.05,
                        label: Self.percent(persona.style.similarity), low: "低", high: "高")
            Hairline()
            VoiceSlider(title: "风格强度", value: style.style, range: 0...1, step: 0.05,
                        label: Self.percent(persona.style.style), low: "平淡", high: "夸张")
            Hairline()
            SettingRow(title: "说话人增强") { InkToggle(isOn: style.speakerBoost, label: "说话人增强") }
        }
    }

    /// MiniMax 音色微调和音效
    private var toneGroup: some View {
        SettingsGroup(title: "音色") {
            VoiceSlider(title: "音高", value: Self.whole(style.tonePitch), range: -100...100, step: 1,
                        label: Self.signed(persona.style.tonePitch), low: "低沉", high: "明亮")
            Hairline()
            VoiceSlider(title: "力度", value: Self.whole(style.intensity), range: -100...100, step: 1,
                        label: Self.signed(persona.style.intensity), low: "有力", high: "柔和")
            Hairline()
            VoiceSlider(title: "质感", value: Self.whole(style.timbre), range: -100...100, step: 1,
                        label: Self.signed(persona.style.timbre), low: "浑厚", high: "清脆")
            Hairline()
            SettingRow(title: "音效") {
                Menu {
                    ForEach(VoiceStyle.effects, id: \.0) { e in
                        Button { persona.style.effect = e.0 } label: {
                            if persona.style.effect == e.0 { Label(LocalizedStringKey(e.1), systemImage: "checkmark") } else { Text(LocalizedStringKey(e.1)) }
                        }
                    }
                } label: {
                    MenuValue(text: VoiceStyle.effects.first { $0.0 == persona.style.effect }?.1 ?? "无")
                }
            }
        }
    }

    /// 混合声音：主声音和最多 3 个别的声音按比重混在一起
    private var mixGroup: some View {
        SettingsGroup(title: "混合声音") {
            if !persona.style.mixes.isEmpty {
                VoiceSlider(title: persona.voiceName.isEmpty ? "主声音" : persona.voiceName, value: Self.whole(style.mainWeight),
                            range: 1...100, step: 1, label: "\(persona.style.mainWeight)")
                ForEach(persona.style.mixes) { mix in
                    Hairline()
                    HStack(alignment: .top, spacing: 0) {
                        VoiceSlider(title: mix.name, value: weight(of: mix.id), range: 1...100, step: 1, label: "\(mix.weight)")
                        Button {
                            withAnimation(Motion.spring) { persona.style.mixes.removeAll { $0.id == mix.id } }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.faint)
                                .frame(width: 36, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除")
                        .padding(.trailing, 4)
                    }
                }
                Hairline()
            }
            if persona.style.mixes.count < 3 {
                Button { addingMix = true } label: {
                    SettingRow(title: "添加声音") {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    }
                }
                .buttonStyle(PressableRowStyle())
            }
        }
    }

    /// 朗读：语言增强、数字读法、读音纠正
    private var readingGroup: some View {
        SettingsGroup(title: "朗读") {
            SettingRow(title: "语言增强") {
                Menu {
                    ForEach(VoiceStyle.languages, id: \.0) { item in
                        Button(LocalizedStringKey(item.1)) { persona.style.languageBoost = item.0 }
                    }
                } label: {
                    MenuValue(text: VoiceStyle.languages.first { $0.0 == persona.style.languageBoost }?.1 ?? persona.style.languageBoost)
                }
            }
            Hairline()
            SettingRow(title: "朗读优化", subtitle: "数字、符号读得更准，稍慢一点") {
                InkToggle(isOn: style.quality, label: "朗读优化")
            }
            Hairline()
            FieldRow(placeholder: "读音纠正，每行一条：重庆/(chong2)(qing4)",
                     text: Binding(get: { persona.style.pronunciations.joined(separator: "\n") },
                                   set: { persona.style.pronunciations = $0.components(separatedBy: "\n") }),
                     multiline: true)
        }
    }

    private func weight(of id: String) -> Binding<Double> {
        Binding(get: { Double(persona.style.mixes.first { $0.id == id }?.weight ?? 50) },
                set: { new in
                    var s = persona.style
                    if let i = s.mixes.firstIndex(where: { $0.id == id }) { s.mixes[i].weight = Int(new.rounded()) }
                    persona.style = s
                })
    }

    private func reset() {
        withAnimation(Motion.spring) {
            persona.voiceSpeed = 1
            persona.voiceVolume = 1
            persona.voicePitch = 0
            persona.voiceEmotion = ""
            // 混合的声音留着，其余回到默认
            var fresh = VoiceStyle()
            fresh.mixes = persona.style.mixes
            persona.style = fresh
        }
    }

    /// 用现在的设置念一句
    private func preview() {
        previewing = true
        failure = nil
        Task {
            defer { previewing = false }
            do {
                let text = persona.lang == .ko ? "오늘 하루 어땠어? 나는 네 생각 많이 했어." : "今天过得怎么样？我可是一直在想你哦。"
                let data = try await Voice.speak(text, for: persona)
                if !player.toggle("tune-\(persona.id)", data: data) { failure = String(localized: "这段声音放不出来。") }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    static func whole(_ value: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) })
    }

    static func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}
