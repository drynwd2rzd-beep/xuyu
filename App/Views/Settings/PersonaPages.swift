import SwiftUI
import SwiftData

/// 角色设置的二级页面：不常改的收在这里，编辑角色的主页面只留资料、人设和互动
enum PersonaPage: Hashable {
    case touch, voice, moments, model

    var title: String {
        switch self {
        case .touch: "真人感"
        case .voice: "语音"
        case .moments: "动态与相册"
        case .model: "模型"
        }
    }
}

struct PersonaSubpage: View {
    @Bindable var persona: Persona
    let page: PersonaPage

    var body: some View {
        SettingsPage(title: page.title) {
            switch page {
            case .touch: TouchRows(persona: persona)
            case .voice: PersonaVoiceGroup(persona: persona)
            case .moments: PersonaMomentsGroups(persona: persona)
            case .model: PersonaModelGroup(persona: persona)
            }
        }
    }
}

/// 真人节奏（会忙、晚点回、补一句、打字犹豫）、小情绪的程度、内心想法。存在本机，见 HumanTouch
private struct TouchRows: View {
    @AppStorage private var pace: Bool
    @AppStorage private var mood: Int
    @AppStorage private var thoughts: Bool

    init(persona: Persona) {
        _pace = AppStorage(wrappedValue: true, HumanTouch.paceKey(persona.id))
        _mood = AppStorage(wrappedValue: 1, HumanTouch.moodKey(persona.id))
        _thoughts = AppStorage(wrappedValue: false, HumanTouch.thoughtsKey(persona.id))
    }

    var body: some View {
        SettingsGroup(title: "节奏") {
            SettingRow(title: "真人节奏", subtitle: "会忙、会晚点回、想起来再补一句") {
                InkToggle(isOn: $pace, label: "真人节奏")
            }
        }
        SettingsGroup(title: "情绪") {
            SettingRow(title: "小情绪") {
                Segmented(items: [(0, "不要"), (1, "一点点"), (2, "明显")], selection: $mood)
                    .fixedSize()
            }
            Hairline()
            SettingRow(title: "内心想法", subtitle: "气泡上方偶尔有一句 TA 的心声") {
                InkToggle(isOn: $thoughts, label: "内心想法")
            }
        }
    }
}

/// 刷视频分享给我：放在编辑角色主页面的「互动」里
struct VideoShareRow: View {
    @AppStorage private var videos: Bool

    init(persona: Persona) {
        _videos = AppStorage(wrappedValue: true, HumanTouch.videosKey(persona.id))
    }

    var body: some View {
        SettingRow(title: "刷视频分享给我", subtitle: "B 站、抖音热搜，一天最多一次") {
            InkToggle(isOn: $videos, label: "刷视频分享给我")
        }
    }
}

/// 语音：先选发不发；发的话再选声音、调声音、说哪种话。TA 打字的语言跟着 App 界面走
private struct PersonaVoiceGroup: View {
    @Bindable var persona: Persona
    @State private var pickingVoice = false
    @State private var tuning = false

    var body: some View {
        SettingsGroup(title: "语音") {
            SettingRow(title: "发语音") {
                Segmented(items: [(0, "不发"), (1, "偶尔"), (2, "常常")], selection: $persona.voiceFreq)
                    .fixedSize()
            }
            if persona.voiceFreq > 0 {
                Hairline()
                Button { pickingVoice = true } label: {
                    SettingRow(title: "声音", subtitle: persona.voiceID.isEmpty ? nil : Voice.provider(of: persona).label) {
                        Text(persona.voiceName.isEmpty ? String(localized: "未选择") : persona.voiceName)
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.inkSoft)
                            .lineLimit(1)
                        Chevron()
                    }
                }
                .buttonStyle(PressableRowStyle())
                .transition(.opacity)
                if !persona.voiceID.isEmpty {
                    Hairline()
                    Button { tuning = true } label: {
                        SettingRow(title: "声音调节", subtitle: voiceModelName) {
                            Text(tuneSummary)
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.inkSoft)
                                .lineLimit(1)
                            Chevron()
                        }
                    }
                    .buttonStyle(PressableRowStyle())
                    .transition(.opacity)
                }
                Hairline()
                SettingRow(title: "语音语言") {
                    Segmented(items: [("zh", "中文"), ("ko", "한국어")], selection: $persona.language)
                        .fixedSize()
                }
                .transition(.opacity)
                // 语音和界面是同一种话就不用翻译
                if persona.language != Self.uiLanguage {
                    Hairline()
                    SettingRow(title: "自动翻译语音") {
                        InkToggle(isOn: $persona.autoTranslate, label: "自动翻译语音")
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(Motion.spring, value: persona.voiceFreq > 0)
        .animation(Motion.spring, value: persona.voiceID)
        .animation(Motion.spring, value: persona.language)
        .sheet(isPresented: $pickingVoice) {
            VoicePicker(persona: persona)
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        .sheet(isPresented: $tuning) {
            VoiceTuneSheet(persona: persona)
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
    }

    /// 「声音调节」那一行右边：调过的才写出来，都是默认就显示「默认」
    private var tuneSummary: String {
        var parts: [String] = []
        if abs(persona.voiceSpeed - 1) > 0.01 { parts.append(String(format: "%.2g×", persona.voiceSpeed)) }
        if persona.voicePitch != 0 { parts.append(persona.voicePitch > 0 ? "+\(persona.voicePitch)" : "\(persona.voicePitch)") }
        if let e = Voice.emotions.first(where: { $0.0 == persona.voiceEmotion }), !e.0.isEmpty { parts.append(String(localized: String.LocalizationValue(e.1))) }
        let style = persona.style
        if let e = VoiceStyle.effects.first(where: { $0.0 == style.effect }), !e.0.isEmpty { parts.append(String(localized: String.LocalizationValue(e.1))) }
        if !style.mixes.isEmpty { parts.append(String(localized: "混合 \(style.mixes.count + 1) 个声音")) }
        return parts.isEmpty ? String(localized: "默认") : parts.joined(separator: " · ")
    }

    /// 「声音调节」那一行下面的小字：现在用的语音模型
    private var voiceModelName: String {
        persona.voiceModel.isEmpty ? Voice.provider(of: persona).defaultModel : persona.voiceModel
    }

    /// App 界面现在是哪种话
    static var uiLanguage: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("ko") == true ? "ko" : "zh"
    }
}

/// 动态：多常发、去不去看别人的；相册里的照片是 TA 发动态、聊天时分享的配图
private struct PersonaMomentsGroups: View {
    @Bindable var persona: Persona

    var body: some View {
        SettingsGroup(title: "动态") {
            SettingRow(title: "发动态") {
                Segmented(items: [(0, "不发"), (1, "偶尔"), (2, "常常")], selection: $persona.momentsFreq)
                    .fixedSize()
            }
            if persona.momentsFreq > 0 {
                Hairline()
                SettingRow(title: "和别的角色互动") {
                    InkToggle(isOn: $persona.momentsMutual, label: "和别的角色互动")
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.spring, value: persona.momentsFreq > 0)
        SettingsGroup(title: "相册") {
            AlbumGrid(personaID: persona.id).padding(Space.item)
        }
    }
}

/// 用什么模型、能不能操作电脑
private struct PersonaModelGroup: View {
    @Bindable var persona: Persona
    @Environment(RelayClient.self) private var relay

    var body: some View {
        SettingsGroup(title: "模型") {
            SettingRow(title: "由谁驱动") {
                Segmented(items: Engine.allCases.map { ($0, $0.label) }, selection: $persona.engine)
                    .fixedSize()
            }
            Hairline()
            SettingRow(title: "模型") {
                Menu {
                    Button("跟随默认") { persona.model = "" }
                    ForEach(models) { m in
                        Button(m.name) { persona.model = m.id }
                    }
                } label: {
                    MenuValue(text: persona.model.isEmpty ? "跟随默认" : ModelNames.name(persona.model, engine: persona.engine, status: relay.status))
                }
            }
            Hairline()
            SettingRow(title: "推理强度") {
                EffortMenu(options: ModelNames.efforts(for: persona.model, engine: persona.engine, status: relay.status),
                           selection: $persona.effort)
            }
        }
        SettingsGroup(title: "工作") {
            SettingRow(title: "允许操作电脑", subtitle: "只在电脑的「絮语工作区」里读写文件、运行命令") {
                InkToggle(isOn: $persona.canWork, label: "允许操作电脑")
            }
        }
    }

    private var models: [ModelInfo] {
        relay.status?.catalog(for: persona.engine) ?? []
    }
}
