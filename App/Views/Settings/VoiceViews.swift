import SwiftUI

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
