import Foundation
import SwiftData

/// 设置里「语音」几页背后的事：试听一个声音、复刻新声音、把声音换给角色、改名和删除自己的声音。
/// 视图只管显示和「正在……」「出错了」这些状态；联网、改角色都在这里（审查 Z-410、ARCH-5）
@MainActor
enum VoiceLibrary {
    // MARK: - 试听

    /// 试听一个声音：有自带的样音（ElevenLabs）就下载下来；没有的用这个声音现念一句（会用一点点额度）。
    /// 现念时照角色的语言说；角色本来就用这家服务时，用角色选的模型念
    static func sample(of voice: Voice.Choice, on provider: VoiceProvider, for persona: Persona) async throws -> Data {
        if let url = voice.preview {
            return try await URLSession.shared.data(from: url).0
        }
        var spec = VoiceSpec(previewing: voice.id, on: provider, language: persona.lang)
        if persona.provider == provider, !persona.voiceModel.isEmpty { spec.model = persona.voiceModel }
        return try await Voice.speak(greeting(persona.lang), spec: spec)
    }

    /// 试听时现念的那一句
    private static func greeting(_ language: PersonaLanguage) -> String {
        language == .ko ? "안녕, 오늘 하루 어땠어?" : "你好呀，今天过得怎么样？"
    }

    // MARK: - 换声音

    /// 把这个声音换给角色；换了服务就把模型和混合声音清掉（两家不通用）。还没开语音的顺手打开
    static func assign(_ voiceID: String, name: String, on provider: VoiceProvider, to persona: Persona) {
        if persona.provider != provider {
            persona.provider = provider
            persona.voiceModel = ""
            persona.style.mixes = []
        }
        persona.voiceID = voiceID
        persona.voiceName = name
        if persona.voiceFreq == 0 { persona.voiceFreq = 1 }
    }

    // MARK: - 复刻

    /// 复刻走到了哪一步（界面按钮里显示对应的字）。开始整理录音时界面自己先显示，不经过这里
    enum CloneStep {
        /// 录音整理好了，正在交给语音服务复刻
        case cloning
        /// 复刻好了，声音已经换给角色，正在用它念一句试听
        case previewing
    }

    /// 复刻要用的材料：界面上选的几段录音和填的选项（见 Voice.CloneRequest）
    struct CloneDraft {
        /// 给声音起的名字（没去掉首尾空白，复刻时再去）
        var name: String
        /// 几段录音或视频，按顺序接成一段
        var clips: [URL]
        /// MiniMax 的参考录音（选填）
        var reference: URL?
        /// 参考录音说的原话；没填就不用参考录音
        var referenceText = ""
        var denoise = true
        var normalize = true
        var languageBoost = ""
        var validation = ""
        var accuracy = 0.7
        /// ElevenLabs：声音的描述
        var description = ""
    }

    /// 复刻一个新声音：合并录音 → 复刻 → 换给角色 → 用它念 sample 这一句 → 放出来。
    /// 每走到下一步告诉界面一声（step）；哪一步失败都把原来的错误抛出去，已经换上的声音不撤回
    static func clone(_ draft: CloneDraft, on provider: VoiceProvider, for persona: Persona,
                      sample: String, step: (CloneStep) -> Void) async throws {
        let name = draft.name.trimmed
        let audio = try await AudioMerge.merge(draft.clips, limit: AudioMerge.cloneLimit)
        var request = Voice.CloneRequest(name: name, audio: audio)
        if provider == .minimax, let reference = draft.reference, !draft.referenceText.trimmed.isEmpty {
            request.reference = try await AudioMerge.merge([reference], limit: AudioMerge.referenceLimit)
            request.referenceText = draft.referenceText
        }
        request.denoise = draft.denoise
        request.normalize = draft.normalize
        request.languageBoost = draft.languageBoost
        request.validation = draft.validation
        request.accuracy = draft.accuracy
        request.description = draft.description
        step(.cloning)
        let id = try await Voice.clone(request, on: provider)
        // 换成新声音，用它念一句（MiniMax 这一句算第一次使用，声音就会一直保留）
        assign(id, name: name, on: provider, to: persona)
        step(.previewing)
        let data = try await Voice.speak(sample, for: persona)
        VoicePlayer.shared.toggle("clone-\(id)", data: data)
    }

    // MARK: - 改名和删除

    /// 改名：语音服务那边改好后，所有用这个声音的角色一起改
    static func rename(_ voice: Voice.Choice, to name: String, on provider: VoiceProvider, context: ModelContext) async throws {
        try await Voice.rename(voice, to: name, on: provider)
        for p in users(of: voice.id, context: context) { p.voiceName = name }
    }

    /// 删除：语音服务那边删掉后，用这个声音的角色变回没有声音
    static func delete(_ voice: Voice.Choice, on provider: VoiceProvider, context: ModelContext) async throws {
        try await Voice.delete(voice, on: provider)
        for p in users(of: voice.id, context: context) {
            p.voiceID = ""
            p.voiceName = ""
        }
    }

    /// 正在用这个声音的角色
    private static func users(of voiceID: String, context: ModelContext) -> [Persona] {
        ((try? context.fetch(FetchDescriptor<Persona>())) ?? []).filter { $0.voiceID == voiceID }
    }
}
