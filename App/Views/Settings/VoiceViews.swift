import SwiftUI

/// 设置 › 语音：填 ElevenLabs 密钥（只存在这台手机的钥匙串里），选语音模型
struct VoiceSettingsView: View {
    @State private var key = ""
    @State private var configured = Voice.isConfigured
    @State private var status: String?
    @State private var models: [Voice.ModelChoice] = []
    @AppStorage(Prefs.voiceModel) private var model = ""

    var body: some View {
        SettingsPage(title: "语音") {
            SettingsGroup(title: "ElevenLabs") {
                if configured {
                    SettingRow(title: "密钥", subtitle: status) {
                        Button("移除") {
                            Voice.setKey("")
                            withAnimation(Motion.spring) { configured = false }
                            status = nil
                        }
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.danger)
                    }
                    Hairline()
                    SettingRow(title: "模型", subtitle: modelNote) {
                        Menu {
                            ForEach(models) { m in
                                Button {
                                    model = m.id == Voice.defaultModel ? "" : m.id
                                } label: {
                                    let on = (model.isEmpty ? Voice.defaultModel : model) == m.id
                                    if on { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                                }
                            }
                        } label: {
                            MenuValue(text: currentModelName)
                        }
                        .disabled(models.isEmpty)
                        .sensoryFeedback(.selection, trigger: model)
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
        }
        .task(id: configured) { await check() }
    }

    private func save() {
        guard !key.trimmed.isEmpty else { return }
        Voice.setKey(key)
        key = ""
        withAnimation(Motion.spring) { configured = true }
    }

    /// 模型下面那句小字说明（没有说明的模型就不显示）
    private var modelNote: String? {
        let note = Voice.modelNote(model.isEmpty ? Voice.defaultModel : model)
        return note.isEmpty ? nil : note
    }

    /// 现在用的模型叫什么（列表还没读到时先显示 id）
    private var currentModelName: String {
        let id = model.isEmpty ? Voice.defaultModel : model
        return models.first { $0.id == id }?.name ?? id
    }

    private func check() async {
        guard configured else { return }
        status = "正在连接…"
        do {
            let voices = try await Voice.voices()
            status = "已连接 · \(voices.count) 个声音"
            models = (try? await Voice.models()) ?? []
        } catch {
            status = error.localizedDescription
        }
    }
}

/// 给角色挑一个声音：列出你 ElevenLabs 声音库里的声音，右边可以先试听
struct VoicePicker: View {
    @Bindable var persona: Persona
    @Environment(\.dismiss) private var dismiss
    @State private var voices: [Voice.Choice] = []
    @State private var failure: String?
    @State private var loadingPreview: String?
    @State private var previews: [String: Data] = [:]

    private var player: VoicePlayer { VoicePlayer.shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if let failure {
                        Text(failure).font(.system(size: 14)).foregroundStyle(Palette.inkSoft).padding(Space.card)
                    } else if voices.isEmpty {
                        ProgressView().padding(Space.section)
                    }
                    ForEach(voices) { v in
                        row(v)
                        if v.id != voices.last?.id { Hairline() }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .card()
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
            do { voices = try await Voice.voices() } catch { failure = error.localizedDescription }
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
                    Text(v.name).font(.system(size: 15)).foregroundStyle(Palette.ink)
                    if !v.detail.isEmpty {
                        Text(v.detail).font(.system(size: 12)).foregroundStyle(Palette.inkSoft).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if persona.voiceID == v.id {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                }
                if v.preview != nil { previewButton(v) }
            }
            .padding(.horizontal, Space.card)
            .frame(minHeight: Space.row + 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
    }

    /// 试听：第一次点先下载样音，之后直接放
    private func previewButton(_ v: Voice.Choice) -> some View {
        Button {
            if let data = previews[v.id] { return player.toggle(v.id, data: data) }
            guard let url = v.preview else { return }
            loadingPreview = v.id
            Task {
                if let (data, _) = try? await URLSession.shared.data(from: url) {
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
