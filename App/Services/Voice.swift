import SwiftUI
import AVFoundation
import Observation

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
}

enum Voice {
    struct Choice: Identifiable, Hashable {
        let id: String
        let name: String
        /// 性别、口音、风格之类的小标签
        let detail: String
        /// ElevenLabs 自带试听；MiniMax 没有，试听时现念一句
        let preview: URL?
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
            case .noKey: "还没有填语音服务的密钥"
            case .badKey: "密钥不对，或者已经失效"
            case .quota: "语音服务的额度用完了"
            case .other(let text): text
            }
        }
    }

    // MARK: - 密钥

    static func key(_ provider: VoiceProvider) -> String { Keychain.get(provider.keyAccount) ?? "" }
    static func setKey(_ key: String, for provider: VoiceProvider) { Keychain.set(key.trimmed, for: provider.keyAccount) }
    static func isConfigured(_ provider: VoiceProvider) -> Bool { !key(provider).isEmpty }
    /// 至少填了一家
    static var isConfigured: Bool { VoiceProvider.allCases.contains { isConfigured($0) } }

    static func provider(of persona: Persona) -> VoiceProvider { VoiceProvider(rawValue: persona.voiceProvider) ?? .elevenlabs }

    /// 这个角色现在能不能发语音
    static func enabled(for persona: Persona) -> Bool {
        isConfigured(provider(of: persona)) && !persona.voiceID.isEmpty && persona.voiceFreq > 0 && !persona.canWork
    }

    // MARK: - 模型

    /// 能用的模型，每个附一句说明。ElevenLabs 从账号里读；MiniMax 是固定的几种
    static func models(_ provider: VoiceProvider) async throws -> [ModelChoice] {
        switch provider {
        case .elevenlabs:
            let (data, response) = try await URLSession.shared.data(for: ElevenLabs.request("v1/models"))
            try ElevenLabs.check(response, data)
            let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            return list.compactMap { m in
                guard let id = m["model_id"] as? String, m["can_do_text_to_speech"] as? Bool == true else { return nil }
                return ModelChoice(id: id, name: m["name"] as? String ?? id, detail: modelNote(id))
            }
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

    // MARK: - 声音

    static func voices(_ provider: VoiceProvider) async throws -> [Choice] {
        switch provider {
        case .elevenlabs: try await ElevenLabs.voices()
        case .minimax: try await MiniMax.voices()
        }
    }

    // MARK: - 复刻

    /// 用一段录音在 MiniMax 复刻一个新声音，返回它的 ID
    static func cloneVoice(audio: Data, fileName: String) async throws -> String {
        guard isConfigured(.minimax) else { throw Failure.noKey }
        return try await MiniMax.clone(audio: audio, fileName: fileName)
    }

// MARK: - 念

    /// 用这个角色的声音和模型把一句话念成语音（mp3）；选的模型用不了就退回最稳定的
    static func speak(_ text: String, for persona: Persona) async throws -> Data {
        let provider = provider(of: persona)
        guard isConfigured(provider) else { throw Failure.noKey }
        let chosen = persona.voiceModel.isEmpty ? provider.defaultModel : persona.voiceModel
        let tries = chosen == provider.fallbackModel ? [chosen] : [chosen, provider.fallbackModel]
        var lastError: Error = Failure.other("没有生成语音")
        for model in tries {
            do {
                switch provider {
                case .elevenlabs:
                    return try await ElevenLabs.speak(text, voiceID: persona.voiceID, model: model)
                case .minimax:
                    return try await MiniMax.speak(text, voiceID: persona.voiceID, model: model, korean: persona.language == "ko")
                }
            } catch Failure.other(let message) {
                // 这个模型用不了：换下一个
                lastError = Failure.other(message)
            }
        }
        throw lastError
    }
}

// MARK: - ElevenLabs

private enum ElevenLabs {
    static let base = URL(string: "https://api.elevenlabs.io")!

    static func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: base.appending(path: path))
        req.timeoutInterval = 40
        req.setValue(Voice.key(.elevenlabs), forHTTPHeaderField: "xi-api-key")
        return req
    }

    static func voices() async throws -> [Voice.Choice] {
        var req = request("v2/voices")
        req.url?.append(queryItems: [URLQueryItem(name: "page_size", value: "100")])
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = root?["voices"] as? [[String: Any]] ?? []
        return list.compactMap { v in
            guard let id = v["voice_id"] as? String else { return nil }
            let labels = (v["labels"] as? [String: Any] ?? [:]).values.compactMap { $0 as? String }
            return Voice.Choice(id: id, name: v["name"] as? String ?? id,
                                detail: labels.prefix(3).joined(separator: " · "),
                                preview: (v["preview_url"] as? String).flatMap(URL.init(string:)))
        }
    }

    static func speak(_ text: String, voiceID: String, model: String) async throws -> Data {
        var req = request("v1/text-to-speech/\(voiceID)")
        req.url?.append(queryItems: [URLQueryItem(name: "output_format", value: "mp3_44100_128")])
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": model,
            // 稍微放开稳定度、带一点风格：更像随口说话，而不是播音
            "voice_settings": ["stability": 0.45, "similarity_boost": 0.8, "style": 0.3, "use_speaker_boost": true],
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
        return data
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw Voice.Failure.other("没有收到回应") }
        guard !(200..<300).contains(http.statusCode) else { return }
        let message = String(data: data, encoding: .utf8) ?? ""
        if message.contains("quota") { throw Voice.Failure.quota }
        if http.statusCode == 401 { throw Voice.Failure.badKey }
        throw Voice.Failure.other("ElevenLabs 出错了（\(http.statusCode)）")
    }
}

// MARK: - MiniMax

private enum MiniMax {
    static let models = ["speech-2.8-hd", "speech-2.8-turbo", "speech-2.6-hd", "speech-2.6-turbo",
                         "speech-02-hd", "speech-02-turbo", "speech-01-hd", "speech-01-turbo"]

    /// 国内版和国际版是两个平台，密钥不通用。国内版换过网址：先用新的，连不上再试旧的
    static var hosts: [String] {
        UserDefaults.standard.string(forKey: Prefs.minimaxRegion) == "global"
            ? ["https://api.minimax.io"]
            : ["https://api.minimax.cn", "https://api.minimaxi.com"]
    }

    static func post(_ path: String, json: [String: Any]) async throws -> [String: Any] {
        try await send(path, contentType: "application/json", body: JSONSerialization.data(withJSONObject: json))
    }

    /// 发给 MiniMax：这个网址连不上就换下一个
    static func send(_ path: String, contentType: String, body: Data, timeout: TimeInterval = 40) async throws -> [String: Any] {
        var lastError: Error = Voice.Failure.other("没有收到回应")
        for host in hosts {
            guard let url = URL(string: host)?.appending(path: path) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = timeout
            req.httpMethod = "POST"
            req.setValue("Bearer \(Voice.key(.minimax))", forHTTPHeaderField: "Authorization")
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                return try check(response, data)
            } catch let error as URLError {
                lastError = error
            }
        }
        throw lastError
    }

    /// 系统自带的、你克隆的、你用文字生成的声音
    static func voices() async throws -> [Voice.Choice] {
        let root = try await post("v1/get_voice", json: ["voice_type": "all"])
        var list: [Voice.Choice] = []
        for (group, label) in [("voice_cloning", "克隆"), ("voice_generation", "生成"), ("system_voice", "")] {
            for v in root[group] as? [[String: Any]] ?? [] {
                guard let id = v["voice_id"] as? String else { continue }
                let notes = (v["description"] as? [String] ?? []).prefix(2).joined(separator: " · ")
                let detail = [label, notes].filter { !$0.isEmpty }.joined(separator: " · ")
                list.append(Voice.Choice(id: id, name: v["voice_name"] as? String ?? id, detail: detail, preview: nil))
            }
        }
        return list
    }

    static func speak(_ text: String, voiceID: String, model: String, korean: Bool) async throws -> Data {
        let root = try await post("v1/t2a_v2", json: [
            "model": model,
            "text": text,
            "stream": false,
            "voice_setting": ["voice_id": voiceID, "speed": 1, "vol": 1, "pitch": 0],
            "audio_setting": ["sample_rate": 32000, "bitrate": 128000, "format": "mp3", "channel": 1],
            "language_boost": korean ? "Korean" : "Chinese",
        ])
        guard let hex = (root["data"] as? [String: Any])?["audio"] as? String, let audio = Data(hex: hex), !audio.isEmpty else {
            throw Voice.Failure.other("MiniMax 没有返回语音")
        }
        return audio
    }

    /// 快速复刻：先把录音传上去，再用它复刻出一个新声音，返回新声音的 ID。
    /// 复刻这一步不收费；第一次用新声音念话时 MiniMax 扣一次复刻费，7 天内不用会被删掉
    static func clone(audio: Data, fileName: String) async throws -> String {
        let boundary = "xuyu-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\nvoice_clone\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let uploaded = try await send("v1/files/upload", contentType: "multipart/form-data; boundary=\(boundary)", body: body, timeout: 120)
        let file = uploaded["file"] as? [String: Any]
        guard let fileID = (file?["file_id"] as? NSNumber)?.int64Value ?? (file?["file_id"] as? String).flatMap({ Int64($0) }) else {
            throw Voice.Failure.other("录音没有传上去")
        }
        // 新声音的 ID：字母开头、只有字母和数字
        let voiceID = "xuyu" + String((0..<12).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! })
        let result = try await post("v1/voice_clone", json: [
            "file_id": fileID,
            "voice_id": voiceID,
            "need_noise_reduction": true,
            "need_volume_normalization": true,
        ])
        if let sensitive = result["input_sensitive"] as? [String: Any], sensitive["type"] as? Int ?? 0 != 0 {
            throw Voice.Failure.other("录音内容没有通过审核")
        }
        return voiceID
    }

    /// MiniMax 出错时 HTTP 也是 200，要看 base_resp.status_code
    static func check(_ response: URLResponse, _ data: Data) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else { throw Voice.Failure.other("没有收到回应") }
        if http.statusCode == 401 { throw Voice.Failure.badKey }
        let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let base = root["base_resp"] as? [String: Any] ?? [:]
        let code = base["status_code"] as? Int ?? (http.statusCode == 200 ? 0 : http.statusCode)
        switch code {
        case 0: return root
        case 1004, 2049: throw Voice.Failure.badKey
        case 1008: throw Voice.Failure.quota
        case 2038: throw Voice.Failure.other("MiniMax 账号还没实名认证，不能复刻")
        case 2013: throw Voice.Failure.other("录音不符合要求：mp3、m4a 或 wav，10 秒到 5 分钟，不超过 20MB")
        default: throw Voice.Failure.other("MiniMax 出错了（\(code)）")
        }
    }
}

private extension Data {
    /// MiniMax 把音频编码成十六进制字符串返回
    init?(hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.utf8.count / 2)
        var high: UInt8?
        for c in hex.utf8 {
            let v: UInt8
            switch c {
            case 48...57: v = c - 48
            case 97...102: v = c - 87
            case 65...70: v = c - 55
            default: return nil
            }
            if let h = high { bytes.append(h << 4 | v); high = nil } else { high = v }
        }
        self.init(bytes)
    }
}

/// 播放语音消息：同一时间只放一条，放下一条时上一条自动停
@MainActor
@Observable
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()

    /// 正在放的是哪条（语音消息的 id，或试听的声音 id）
    private(set) var playing: String?
    /// 播放进度 0～1
    private(set) var progress: Double = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var durations: [String: TimeInterval] = [:]

    func toggle(_ id: String, data: Data) {
        if playing == id { return stop() }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.delegate = self
        player.play()
        self.player = player
        playing = id
        progress = 0
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let p = self.player, p.duration > 0 else { continue }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    func stop() {
        ticker?.cancel()
        player?.stop()
        player = nil
        withAnimation(Motion.snappy) {
            playing = nil
            progress = 0
        }
    }

    /// 语音有多长（算一次记下来）
    func duration(_ id: String, data: Data) -> TimeInterval {
        if let known = durations[id] { return known }
        let seconds = (try? AVAudioPlayer(data: data))?.duration ?? 0
        durations[id] = seconds
        return seconds
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
