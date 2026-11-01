import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - 复刻

/// 复刻新声音：起名字、选一段或几段录音（视频也行，自动取出声音、接成一段、压缩），官网能填的选项都在这里。
/// 复刻好后换成这个声音，用它念一句试听（整条流程见 VoiceLibrary.clone）
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

    /// 选进来的一段录音（已经拷到临时文件夹）
    struct Clip: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let seconds: Double
    }

    /// 选文件是给哪一项选：复刻用的录音，还是参考录音
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
            clipsGroup
            if provider == .minimax {
                referenceGroup
            }
            optionsGroup
            SettingsGroup(title: "试听") {
                FieldRow(placeholder: defaultSample, text: $sample, multiline: true)
            }
            cloneButton
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

    // MARK: - 分组

    /// 录音：10 秒到 5 分钟，只有一个人说话；几段会按顺序接起来
    private var clipsGroup: some View {
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
    }

    /// 参考录音（只有 MiniMax）：8 秒以内的一小段和它说的原话，让声音更像、更稳（选填）
    private var referenceGroup: some View {
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

    /// 选项：只显示这家服务能填的
    private var optionsGroup: some View {
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
    }

    /// 复刻按钮：MiniMax 会扣费，先确认一次；进行中显示走到哪一步
    private var cloneButton: some View {
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
    }

    // MARK: - 操作

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

    /// 复刻：这里只管按钮上的字和出错提示，合并、复刻、换声音、试听都交给 VoiceLibrary.clone
    private func clone() {
        failure = nil
        working = "正在整理录音…"
        let draft = VoiceLibrary.CloneDraft(name: name, clips: clips.map(\.url), reference: reference?.url,
                                            referenceText: referenceText, denoise: denoise, normalize: normalize,
                                            languageBoost: languageBoost, validation: validation, accuracy: accuracy,
                                            description: detail)
        let line = sample.trimmed.isEmpty ? defaultSample : sample.trimmed
        Task {
            do {
                try await VoiceLibrary.clone(draft, on: provider, for: persona, sample: line) { step in
                    switch step {
                    case .cloning:
                        working = "正在复刻…"
                    case .previewing:
                        onDone()
                        working = "正在试听…"
                    }
                }
                working = nil
                dismiss()
            } catch {
                working = nil
                failure = error.localizedDescription
            }
        }
    }

    /// 录音时长写成「1:05」
    static func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
