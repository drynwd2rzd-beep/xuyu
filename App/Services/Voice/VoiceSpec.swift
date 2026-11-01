import Foundation

/// 念一句话要用的全部声音设置。角色（SwiftData 模型）只能在主线程上读，
/// 所以先在主线程上把要用的字段拷成这个值，再交给联网合成的后台代码（审查 Z-167、CONC-2）
struct VoiceSpec: Sendable {
    var provider: VoiceProvider
    /// 选的模型（没选就是这家的默认模型）
    var model: String
    var voiceID: String
    var speed: Double = 1
    var volume: Double = 1
    var pitch: Int = 0
    /// MiniMax 的情绪（空 = 自动）
    var emotion = ""
    /// 语音说哪种话
    var language: PersonaLanguage = .zh
    var style = VoiceStyle()
}

extension VoiceSpec {
    /// 这个角色现在的声音设置
    @MainActor
    init(_ persona: Persona) {
        let provider = Voice.provider(of: persona)
        self.init(provider: provider,
                  model: persona.voiceModel.isEmpty ? provider.defaultModel : persona.voiceModel,
                  voiceID: persona.voiceID, speed: persona.voiceSpeed, volume: persona.voiceVolume,
                  pitch: persona.voicePitch, emotion: persona.voiceEmotion, language: persona.lang, style: persona.style)
    }

    /// 试听一个还没选上的声音：其余都用默认设置
    init(previewing voiceID: String, on provider: VoiceProvider, language: PersonaLanguage) {
        self.init(provider: provider, model: provider.defaultModel, voiceID: voiceID, language: language)
    }
}
