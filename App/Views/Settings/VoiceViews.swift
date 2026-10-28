import SwiftUI
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
    @AppStorage(Prefs.minimaxRegion) private var region = "cn"

    var body: some View {
        SettingsGroup(title: provider.label) {
            if provider == .minimax {
                SettingRow(title: "平台") {
                    Segmented(items: [("cn", "国内版"), ("global", "国际版")], selection: $region)
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
        status = "正在连接…"
        do {
            let voices = try await Voice.voices(provider)
            status = "已连接 · \(voices.count) 个声音"
        } catch {
            status = error.localizedDescription
        }
    }
}

/// 给角色挑一个声音：列出这家服务里能用的声音，右边可以先试听
struct VoicePicker: View {
    @Bindable var persona: Persona
    @Environment(\.dismiss) private var dismiss
    @State private var voices: [Voice.Choice] = []
    @State private var failure: String?
    @State private var query = ""
    @State private var customID = ""
    @State private var picking = false
    @State private var recording: CloneSource?
    /// 复刻那一行下面的小字（进度、结果、出错原因）
    @State private var cloning: String?
    @State private var isCloning = false
    @State private var loadingPreview: String?
    @State private var previews: [String: Data] = [:]

    private var player: VoicePlayer { VoicePlayer.shared }
    private var provider: VoiceProvider { Voice.provider(of: persona) }

    /// MiniMax 自带的声音很多：可以搜名字和描述
    private var shown: [Voice.Choice] {
        let q = query.trimmed
        guard !q.isEmpty else { return voices }
        return voices.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.detail.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.section) {
                    if provider == .minimax { cloneRow }
                    // 刚克隆好的声音，要合成过一次才会出现在下面的列表里：直接填它的 ID 也能马上用
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
                    if voices.count > 12 {
                        SearchField(text: $query, placeholder: "搜索")
                    }
                    VStack(spacing: 0) {
                        if let failure {
                            Text(failure).font(.system(size: 14)).foregroundStyle(Palette.inkSoft).padding(Space.card)
                        } else if voices.isEmpty {
                            ProgressView().padding(Space.section)
                        }
                        ForEach(shown) { v in
                            row(v)
                            if v.id != shown.last?.id { Hairline() }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .card()
                }
                .padding(Space.page)
            }
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle("选择声音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
        .task {
            do { voices = try await Voice.voices(provider) } catch { failure = error.localizedDescription }
        }
        .onDisappear { player.stop() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.mp3, .mpeg4Audio, .wav, .audio]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return cloning = "读不出这段录音" }
            guard data.count <= 20 * 1024 * 1024 else { return cloning = "录音太大了（最多 20MB）" }
            recording = CloneSource(data: data, name: url.lastPathComponent)
        }
        .confirmationDialog("用这段录音复刻一个声音？", isPresented: Binding(get: { recording != nil }, set: { if !$0 { recording = nil } }),
                            titleVisibility: .visible, presenting: recording) { source in
            Button("复刻并试听") { clone(source) }
        } message: { _ in
            Text("复刻好后会马上用新声音念一句给你听：第一次使用时 MiniMax 会扣一次复刻费。")
        }
    }

    /// 复刻新声音：选一段 10 秒到 5 分钟的清晰录音（只有一个人说话、没有背景音乐）
    private var cloneRow: some View {
        Button { picking = true } label: {
            SettingRow(title: "复刻新声音", subtitle: cloning) {
                if isCloning {
                    ProgressView().controlSize(.small)
                } else {
                    Chevron()
                }
            }
        }
        .buttonStyle(PressableRowStyle())
        .disabled(isCloning)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .card()
    }

    /// 上传、复刻，再用新声音念一句：这一句算第一次使用，声音就会一直保留
    private func clone(_ source: CloneSource) {
        cloning = "正在复刻…"
        isCloning = true
        Task {
            defer { isCloning = false }
            do {
                let id = try await Voice.cloneVoice(audio: source.data, fileName: source.name)
                persona.voiceID = id
                persona.voiceName = String(localized: "我的复刻") + " · " + Fmt.md.string(from: .now)
                if persona.voiceFreq == 0 { persona.voiceFreq = 1 }
                let sample = try await Voice.speak(persona.language == "ko" ? "안녕, 이제 이 목소리로 말할게." : "你好呀，以后我就用这个声音跟你说话啦。", for: persona)
                player.toggle(id, data: sample)
                cloning = "复刻好了，已经换成这个声音"
            } catch {
                cloning = error.localizedDescription
            }
        }
    }

    /// 用填进来的声音 ID（名字就先显示 ID）
    private func useCustomID() {
        let id = customID.trimmed
        guard !id.isEmpty else { return }
        persona.voiceID = id
        persona.voiceName = id
        if persona.voiceFreq == 0 { persona.voiceFreq = 1 }
        dismiss()
    }

    private func row(_ v: Voice.Choice) -> some View {
        Button {
            persona.voiceID = v.id
            persona.voiceName = v.name
            if persona.voiceFreq == 0 { persona.voiceFreq = 1 }
            dismiss()
        } label: {
            HStack(spacing: Space.item) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.name).font(.system(size: 15)).foregroundStyle(Palette.ink).lineLimit(1)
                    if !v.detail.isEmpty {
                        Text(v.detail).font(.system(size: 12)).foregroundStyle(Palette.inkSoft).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if persona.voiceID == v.id {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                }
                previewButton(v)
            }
            .padding(.horizontal, Space.card)
            .frame(minHeight: Space.row + 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
    }

    /// 试听：ElevenLabs 下载自带的样音；MiniMax 用这个声音现念一句（会用一点点额度）
    private func previewButton(_ v: Voice.Choice) -> some View {
        Button {
            if let data = previews[v.id] { return player.toggle(v.id, data: data) }
            loadingPreview = v.id
            Task {
                let data: Data?
                if let url = v.preview {
                    data = try? await URLSession.shared.data(from: url).0
                } else {
                    let sample = Persona(name: "")
                    sample.voiceProvider = persona.voiceProvider
                    sample.voiceModel = persona.voiceModel
                    sample.voiceID = v.id
                    sample.language = persona.language
                    data = try? await Voice.speak(persona.language == "ko" ? "안녕, 오늘 하루 어땠어?" : "你好呀，今天过得怎么样？", for: sample)
                }
                if let data {
                    previews[v.id] = data
                    player.toggle(v.id, data: data)
                }
                loadingPreview = nil
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

/// 给角色挑语音模型：每个模型都写明侧重点（更像真人 / 更快 / 更省…）
struct VoiceModelPicker: View {
    @Bindable var persona: Persona
    @Environment(\.dismiss) private var dismiss
    @State private var models: [Voice.ModelChoice] = []
    @State private var failure: String?

    private var provider: VoiceProvider { Voice.provider(of: persona) }
    private var current: String { persona.voiceModel.isEmpty ? provider.defaultModel : persona.voiceModel }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if let failure {
                        Text(failure).font(.system(size: 14)).foregroundStyle(Palette.inkSoft).padding(Space.card)
                    } else if models.isEmpty {
                        ProgressView().padding(Space.section)
                    }
                    ForEach(models) { m in
                        Button {
                            persona.voiceModel = m.id == provider.defaultModel ? "" : m.id
                            dismiss()
                        } label: {
                            SettingRow(title: m.name, subtitle: m.detail.isEmpty ? nil : m.detail) {
                                if current == m.id {
                                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                                }
                            }
                        }
                        .buttonStyle(PressableRowStyle())
                        if m.id != models.last?.id { Hairline() }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .card()
                .padding(Space.page)
            }
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
        .task {
            do { models = try await Voice.models(provider) } catch { failure = error.localizedDescription }
        }
    }
}

/// 选好的复刻用录音
struct CloneSource: Identifiable {
    let id = UUID()
    let data: Data
    let name: String
}

/// 声音调节：语速、音量、音调、情绪，调完马上试听。只显示这家服务支持的几项
struct VoiceTuneSheet: View {
    @Bindable var persona: Persona
    @Environment(\.dismiss) private var dismiss
    @State private var previewing = false
    @State private var failure: String?

    private var provider: VoiceProvider { Voice.provider(of: persona) }
    private var player: VoicePlayer { VoicePlayer.shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.section) {
                    SettingsGroup(title: "调节") {
                        slider("语速", value: $persona.voiceSpeed,
                               range: provider == .minimax ? 0.5...2 : 0.7...1.2, step: 0.05,
                               label: String(format: "%.2g×", persona.voiceSpeed))
                        if provider == .minimax {
                            Hairline()
                            slider("音量", value: $persona.voiceVolume, range: 0.3...3, step: 0.1,
                                   label: String(format: "%.1f", persona.voiceVolume))
                            Hairline()
                            slider("音调", value: Binding(get: { Double(persona.voicePitch) }, set: { persona.voicePitch = Int($0.rounded()) }),
                                   range: -12...12, step: 1, label: persona.voicePitch > 0 ? "+\(persona.voicePitch)" : "\(persona.voicePitch)")
                            Hairline()
                            SettingRow(title: "情绪") {
                                Menu {
                                    ForEach(Voice.emotions, id: \.0) { e in
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
                    HStack(spacing: Space.item) {
                        Button("恢复默认") {
                            withAnimation(Motion.spring) {
                                persona.voiceSpeed = 1
                                persona.voiceVolume = 1
                                persona.voicePitch = 0
                                persona.voiceEmotion = ""
                            }
                        }
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
                        Text(failure).font(.system(size: 13)).foregroundStyle(Palette.inkSoft)
                    }
                }
                .padding(Space.page)
            }
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle("声音调节")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.fontWeight(.semibold) }
            }
        }
        .onDisappear { player.stop() }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(title)).font(.system(size: 16)).foregroundStyle(Palette.ink)
                Spacer()
                Text(label).font(.system(size: 14).monospacedDigit()).foregroundStyle(Palette.inkSoft)
            }
            Slider(value: value, in: range, step: step).tint(Palette.ink)
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, Space.item)
    }

    /// 用现在的调节念一句
    private func preview() {
        previewing = true
        failure = nil
        Task {
            defer { previewing = false }
            do {
                let text = persona.language == "ko" ? "오늘 하루 어땠어? 나는 네 생각 많이 했어." : "今天过得怎么样？我可是一直在想你哦。"
                let data = try await Voice.speak(text, for: persona)
                player.toggle("tune-\(persona.id)", data: data)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
