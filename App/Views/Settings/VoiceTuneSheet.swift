import SwiftUI
import SwiftData

// MARK: - 滑杆

/// 滑杆一行：标题、数值，两头可以写上是什么方向（声音调节和复刻页都用）
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

// MARK: - 声音调节

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

    // MARK: - 分组

    /// 模型：每个都写明侧重点
    private var modelGroup: some View {
        SettingsGroup(title: "模型") {
            if let modelFailure {
                Text(modelFailure).font(.system(size: 14)).foregroundStyle(Palette.inkSoft).padding(Space.card)
            } else if models.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(Space.card)
            }
            ForEach(Array(models.enumerated()), id: \.element.id) { index, m in
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

    /// 基础：语速；MiniMax 还有音量、音调、情绪
    private var basicGroup: some View {
        SettingsGroup(title: "基础") {
            VoiceSlider(title: "语速", value: $persona.voiceSpeed,
                        range: provider == .minimax ? 0.5...2 : 0.7...1.2, step: 0.05,
                        label: String(format: "%.2g×", persona.voiceSpeed), low: "慢", high: "快")
            if provider == .minimax {
                VoiceSlider(title: "音量", value: $persona.voiceVolume, range: 0.1...10, step: 0.1,
                            label: String(format: "%.1f", persona.voiceVolume), low: "轻", high: "响")
                VoiceSlider(title: "音调", value: Self.whole($persona.voicePitch), range: -12...12, step: 1,
                            label: Self.signed(persona.voicePitch), low: "低", high: "高")
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
            VoiceSlider(title: "相似度", value: style.similarity, range: 0...1, step: 0.05,
                        label: Self.percent(persona.style.similarity), low: "低", high: "高")
            VoiceSlider(title: "风格强度", value: style.style, range: 0...1, step: 0.05,
                        label: Self.percent(persona.style.style), low: "平淡", high: "夸张")
            SettingRow(title: "说话人增强") { InkToggle(isOn: style.speakerBoost, label: "说话人增强") }
        }
    }

    /// MiniMax 音色微调和音效
    private var toneGroup: some View {
        SettingsGroup(title: "音色") {
            VoiceSlider(title: "音高", value: Self.whole(style.tonePitch), range: -100...100, step: 1,
                        label: Self.signed(persona.style.tonePitch), low: "低沉", high: "明亮")
            VoiceSlider(title: "力度", value: Self.whole(style.intensity), range: -100...100, step: 1,
                        label: Self.signed(persona.style.intensity), low: "有力", high: "柔和")
            VoiceSlider(title: "质感", value: Self.whole(style.timbre), range: -100...100, step: 1,
                        label: Self.signed(persona.style.timbre), low: "浑厚", high: "清脆")
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
            SettingRow(title: "朗读优化", subtitle: "数字、符号读得更准，稍慢一点") {
                InkToggle(isOn: style.quality, label: "朗读优化")
            }
            FieldRow(placeholder: "读音纠正，每行一条：重庆/(chong2)(qing4)",
                     text: Binding(get: { persona.style.pronunciations.joined(separator: "\n") },
                                   set: { persona.style.pronunciations = $0.components(separatedBy: "\n") }),
                     multiline: true)
        }
    }

    // MARK: - 操作

    /// 某个混合声音的比重（滑杆用 Double，存的是整数）
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

    // MARK: - 换算

    /// 整数设置接到滑杆上（滑杆只认 Double）
    static func whole(_ value: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) })
    }

    /// 带正负号的整数：+3、0、-2
    static func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
    /// 0～1 写成百分数
    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}
