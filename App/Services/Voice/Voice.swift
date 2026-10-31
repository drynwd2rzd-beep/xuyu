import SwiftUI
import os

/// 语音服务：ElevenLabs 和 MiniMax 两家。每个角色自己选用哪家、哪个模型、哪个声音。
/// 密钥只存在这台手机的钥匙串里，App 直接和语音服务通信（不经过电脑）
enum VoiceProvider: String, CaseIterable, Identifiable {
    case elevenlabs, minimax
    var id: String { rawValue }

    var label: String {
        switch self {
        case .elevenlabs: "ElevenLabs"
        case .minimax: "MiniMax"
        }
    }

    /// 没选模型时用的
    var defaultModel: String {
        switch self {
        case .elevenlabs: "eleven_v4"
        case .minimax: "speech-2.8-hd"
        }
    }

    /// 选的模型用不了时退回这个
    var fallbackModel: String {
        switch self {
        case .elevenlabs: "eleven_multilingual_v2"
        case .minimax: "speech-02-hd"
        }
    }

    fileprivate var keyAccount: String { rawValue }

    /// 充值、看余额的网页（MiniMax 国内版和国际版是两个平台）
    var topUpURL: URL {
        switch self {
        case .elevenlabs:
            return URL(string: "https://elevenlabs.io/app/subscription")!
        case .minimax:
            return URL(string: MiniMaxRegion.current == .global ? "https://platform.minimax.io/user-center/payment/balance"
                                                                : "https://platform.minimaxi.com/user-center/payment/balance")!
        }
    }
}

/// MiniMax 用国内版还是国际版（存在 Prefs.minimaxRegion，存的字符串不能改）
enum MiniMaxRegion: String {
    case cn, global

    static var current: MiniMaxRegion {
        MiniMaxRegion(rawValue: UserDefaults.standard.string(forKey: Prefs.minimaxRegion) ?? "") ?? .cn
    }
}

extension Persona {
    /// 发语音用哪家（存的是 voiceProvider 字符串，兜底 ElevenLabs）
    var provider: VoiceProvider {
        get { VoiceProvider(rawValue: voiceProvider) ?? .elevenlabs }
        set { voiceProvider = newValue.rawValue }
    }
}

enum Voice {
    struct Choice: Identifiable, Hashable {
        let id: String
        let name: String
        /// 性别、口音、风格之类的小标签
        let detail: String
        /// ElevenLabs 自带试听；MiniMax 没有，试听时现念一句
        let preview: URL?
        /// 自己复刻或生成的：可以改名、删除
        var mine = false
        /// MiniMax 删除时要写的类型（voice_cloning / voice_generation）
        var kind = ""
    }

    struct ModelChoice: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String
    }

    enum Failure: LocalizedError {
        case noKey, badKey, quota, other(String)

        var errorDescription: String? {
            switch self {
            case .noKey: String(localized: "还没有填语音服务的密钥")
            case .badKey: String(localized: "密钥不对，或者已经失效")
            case .quota: String(localized: "语音服务的额度用完了")
            case .other(let text): String(localized: String.LocalizationValue(text))
            }
        }
    }

    // MARK: - 密钥

    static func key(_ provider: VoiceProvider) -> String { Keychain.get(provider.keyAccount) ?? "" }
    static func setKey(_ key: String, for provider: VoiceProvider) { Keychain.set(key.trimmed, for: provider.keyAccount) }
    static func isConfigured(_ provider: VoiceProvider) -> Bool { !key(provider).isEmpty }
    /// 至少填了一家
    static var isConfigured: Bool { VoiceProvider.allCases.contains { isConfigured($0) } }
    /// 填了密钥的几家
    static var configured: [VoiceProvider] { VoiceProvider.allCases.filter { isConfigured($0) } }

    /// 角色用的那家；还没选声音、那家又没填密钥时，用填了密钥的那家
    static func provider(of persona: Persona) -> VoiceProvider {
        let chosen = persona.provider
        if isConfigured(chosen) || !persona.voiceID.isEmpty { return chosen }
        return configured.first ?? chosen
    }

    /// 这个角色现在能不能发语音
    static func enabled(for persona: Persona) -> Bool {
        isConfigured(provider(of: persona)) && !persona.voiceID.isEmpty && persona.voiceFreq > 0 && !persona.canWork
    }

    /// 这个角色的模型能念哪种语气标签：MiniMax 2.8 写 (laughs)，ElevenLabs v3/v4 写 [laughs]；不支持就是 nil
    static func tagStyle(for persona: Persona) -> VoiceProvider? {
        let provider = provider(of: persona)
        let model = persona.voiceModel.isEmpty ? provider.defaultModel : persona.voiceModel
        return supportsTags(model, provider) ? provider : nil
    }

    private static func supportsTags(_ model: String, _ provider: VoiceProvider) -> Bool {
        switch provider {
        case .minimax: model.hasPrefix("speech-2.8")
        case .elevenlabs: model.contains("v3") || model.contains("v4")
        }
    }

    // MARK: - 模型

    /// 能用的模型，每个附一句说明。ElevenLabs 从账号里读；MiniMax 是固定的几种
    static func models(_ provider: VoiceProvider) async throws -> [ModelChoice] {
        switch provider {
        case .elevenlabs:
            return try await ElevenLabs.models().map { ModelChoice(id: $0.id, name: $0.name, detail: modelNote($0.id)) }
        case .minimax:
            return MiniMax.models.map { ModelChoice(id: $0, name: $0, detail: modelNote($0)) }
        }
    }

    /// 每个模型一句话说明，方便挑
    static func modelNote(_ id: String) -> String {
        switch id {
        // ElevenLabs
        case "eleven_v4": "情感最丰富，最像真人"
        case "eleven_v4_turbo": "很有感情，生成更快"
        case "eleven_v3": "表现力强，语气起伏大"
        case "eleven_v3_conversational": "适合对话，生成快"
        case "eleven_multilingual_v2": "最稳定，长句也不走样"
        case "eleven_flash_v2_5": "最快、最省额度"
        case "eleven_turbo_v2_5": "快，适合短句"
        // MiniMax
        case "speech-2.8-hd": "最新，最自然，能念出笑声、叹气这类语气"
        case "speech-2.8-turbo": "最新，更快更省，也能念语气"
        case "speech-2.6-hd": "细腻，支持耳语、平稳两种说法"
        case "speech-2.6-turbo": "更快更省，支持耳语"
        case "speech-02-hd": "音质好、很稳定"
        case "speech-02-turbo": "快、省额度"
        case "speech-01-hd": "老版本，音质好"
        case "speech-01-turbo": "老版本，快"
        default: ""
        }
    }

    /// MiniMax 能选的情绪（空 = 自动）。耳语、平稳只有 2.6 模型支持
    static let emotions: [(String, String)] = [
        ("", "自动"), ("happy", "开心"), ("calm", "平静"), ("sad", "悲伤"), ("angry", "生气"),
        ("surprised", "惊讶"), ("fearful", "害怕"), ("disgusted", "厌恶"), ("whisper", "耳语"), ("fluent", "平稳"),
    ]

    // MARK: - 声音

    /// 这家的全部声音；自己起过名字的显示自己起的名字
    static func voices(_ provider: VoiceProvider) async throws -> [Choice] {
        let list = switch provider {
        case .elevenlabs: try await ElevenLabs.voices()
        case .minimax: try await MiniMax.voices()
        }
        let names = VoiceNames.all
        return list.map { v in
            guard let name = names[v.id] else { return v }
            return Choice(id: v.id, name: name, detail: v.detail, preview: v.preview, mine: v.mine, kind: v.kind)
        }
    }

    /// 改名：ElevenLabs 连账号里的名字一起改；MiniMax 的声音没有名字，记在这台手机上
    static func rename(_ voice: Choice, to name: String, on provider: VoiceProvider) async throws {
        let name = name.trimmed
        guard !name.isEmpty else { return }
        if provider == .elevenlabs && voice.mine { try await ElevenLabs.rename(voice.id, to: name) }
        VoiceNames.set(name, for: voice.id)
    }

    /// 删除自己复刻的声音（删了就找不回来，ID 也不能再用）
    static func delete(_ voice: Choice, on provider: VoiceProvider) async throws {
        switch provider {
        case .elevenlabs: try await ElevenLabs.delete(voice.id)
        case .minimax: try await MiniMax.delete(voice.id, kind: voice.kind.isEmpty ? "voice_cloning" : voice.kind)
        }
        VoiceNames.set(nil, for: voice.id)
    }

    // MARK: - 复刻

    /// 复刻要填的东西：官网能填的都在这里
    struct CloneRequest {
        var name: String
        /// 合成好的一段录音（m4a）
        var audio: Data
        /// MiniMax：8 秒以内的参考录音和它说的原话，让声音更像、更稳
        var reference: Data?
        var referenceText = ""
        /// 降噪（ElevenLabs 叫去除背景噪音）
        var denoise = true
        /// MiniMax：音量统一
        var normalize = true
        /// MiniMax：语言增强（空 = 不设）
        var languageBoost = ""
        /// MiniMax：录音里说的原话，用来核对录音；对不上就复刻失败
        var validation = ""
        var accuracy = 0.7
        /// ElevenLabs：声音的描述
        var description = ""
    }

    /// 复刻一个新声音，返回它的 ID；名字记下来
    static func clone(_ request: CloneRequest, on provider: VoiceProvider) async throws -> String {
        guard isConfigured(provider) else { throw Failure.noKey }
        let id = switch provider {
        case .elevenlabs: try await ElevenLabs.clone(request)
        case .minimax: try await MiniMax.clone(request)
        }
        VoiceNames.set(request.name, for: id)
        return id
    }

    // MARK: - 念

    /// 用这个角色的声音和设置把一句话念成语音（mp3）；选的模型用不了就退回最稳定的。
    /// 话里可以带语气标签（笑、叹气、停顿），模型不支持时先去掉
    static func speak(_ text: String, for persona: Persona) async throws -> Data {
        let provider = provider(of: persona)
        guard isConfigured(provider) else { throw Failure.noKey }
        let chosen = persona.voiceModel.isEmpty ? provider.defaultModel : persona.voiceModel
        let tries = chosen == provider.fallbackModel ? [chosen] : [chosen, provider.fallbackModel]
        var lastError: Error = Failure.other("没有生成语音")
        for model in tries {
            let line = supportsTags(model, provider) ? text : VoiceTags.strip(text)
            do {
                switch provider {
                case .elevenlabs: return try await ElevenLabs.speak(line, persona: persona, model: model)
                case .minimax: return try await MiniMax.speak(line, persona: persona, model: model)
                }
            } catch Failure.other(let message) {
                // 这个模型用不了：换下一个
                lastError = Failure.other(message)
            }
        }
        throw lastError
    }
}

/// 自己给声音起的名字，存在这台手机上（会跟着备份走）
enum VoiceNames {
    /// 读坏了不会清空：原来的内容留底在「voiceNames.broken」，下次改名字也不会把其余名字冲掉（Storage.decodeDefault）
    static var all: [String: String] {
        Storage.decodeDefault([String: String].self, key: Prefs.voiceNames) ?? [:]
    }

    static func set(_ name: String?, for id: String) {
        var map = all
        let clean = name?.trimmed ?? ""
        map[id] = clean.isEmpty ? nil : clean
        do {
            UserDefaults.standard.set(String(decoding: try JSONEncoder().encode(map), as: UTF8.self), forKey: Prefs.voiceNames)
        } catch {
            Log.voice.error("声音名字没能保存：\(error.localizedDescription, privacy: .public)")
        }
    }
}

/// 拼一个 multipart/form-data 请求体（上传录音用）
struct Multipart {
    let boundary = "xuyu-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func file(_ name: String, fileName: String, mime: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finished() -> Data { body + Data("--\(boundary)--\r\n".utf8) }
}
