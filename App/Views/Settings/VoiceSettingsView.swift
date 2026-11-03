import SwiftUI

// MARK: - 语音总页

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

// MARK: - 语音几页共用的小件

/// 语音相关的弹出页（选声音、复刻、声音调节）：标题、关闭或完成、纸色背景
struct VoiceSheet<Content: View>: View {
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

/// 语音弹出页设置组里的一行输入框（可以是多行）
struct FieldRow: View {
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
