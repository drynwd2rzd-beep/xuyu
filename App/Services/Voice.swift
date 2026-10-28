import SwiftUI
import AVFoundation
import Observation

/// ElevenLabs 语音：TA 发语音消息时，把那句话用 TA 的声音念出来。
/// 密钥只存在这台手机的钥匙串里，App 直接和 ElevenLabs 通信（不经过电脑）
enum Voice {
    private static let keyAccount = "elevenlabs"
    private static let base = URL(string: "https://api.elevenlabs.io")!
    /// 没选模型时用情感最丰富的 v4
    static let defaultModel = "eleven_v4"
    /// 选的模型用不了时退回这个：最稳定、支持中文和韩语
    private static let fallbackModel = "eleven_multilingual_v2"

    /// 设置里选的语音模型（空 = 默认）
    static var model: String {
        let chosen = UserDefaults.standard.string(forKey: Prefs.voiceModel) ?? ""
        return chosen.isEmpty ? defaultModel : chosen
    }

    static var apiKey: String { Keychain.get(keyAccount) ?? "" }
    static var isConfigured: Bool { !apiKey.isEmpty }

    static func setKey(_ key: String) { Keychain.set(key.trimmed, for: keyAccount) }

    /// 这个角色现在能不能发语音
    static func enabled(for persona: Persona) -> Bool {
        isConfigured && !persona.voiceID.isEmpty && persona.voiceFreq > 0 && !persona.canWork
    }

    struct Choice: Identifiable, Hashable {
        let id: String
        let name: String
        /// 性别、口音、风格之类的小标签
        let detail: String
        let preview: URL?
    }

    enum Failure: LocalizedError {
        case noKey, badKey, quota, other(String)

        var errorDescription: String? {
            switch self {
            case .noKey: "还没有填 ElevenLabs 密钥"
            case .badKey: "密钥不对，或者已经失效"
            case .quota: "ElevenLabs 的额度用完了"
            case .other(let text): text
            }
        }
    }

    /// 你的声音库：自带的、克隆的、从社区收藏的
    static func voices() async throws -> [Choice] {
        var url = base.appending(path: "v2/voices")
        url.append(queryItems: [URLQueryItem(name: "page_size", value: "100")])
        let (data, response) = try await URLSession.shared.data(for: request(url))
        try check(response, data)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = root?["voices"] as? [[String: Any]] ?? []
        return list.compactMap { v in
            guard let id = v["voice_id"] as? String else { return nil }
            let labels = (v["labels"] as? [String: Any] ?? [:]).values.compactMap { $0 as? String }
            return Choice(id: id, name: v["name"] as? String ?? id,
                          detail: labels.prefix(3).joined(separator: " · "),
                          preview: (v["preview_url"] as? String).flatMap(URL.init(string:)))
        }
    }

    /// 你的账号能用的语音模型（只要能把文字念出来的）
    struct ModelChoice: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String
    }

    static func models() async throws -> [ModelChoice] {
        let (data, response) = try await URLSession.shared.data(for: request(base.appending(path: "v1/models")))
        try check(response, data)
        let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return list.compactMap { m in
            guard let id = m["model_id"] as? String, m["can_do_text_to_speech"] as? Bool == true else { return nil }
            return ModelChoice(id: id, name: m["name"] as? String ?? id, detail: modelNote(id))
        }
    }

    /// 每个模型一句话说明，方便挑
    static func modelNote(_ id: String) -> String {
        switch id {
        case "eleven_v4": "情感最丰富，最像真人"
        case "eleven_v4_turbo": "很有感情，生成更快"
        case "eleven_v3": "表现力强，语气起伏大"
        case "eleven_v3_conversational": "适合对话，生成快"
        case "eleven_multilingual_v2": "最稳定，支持中文和韩语"
        case "eleven_flash_v2_5": "最快、最省额度"
        case "eleven_turbo_v2_5": "快，适合短句"
        default: ""
        }
    }

    /// 把一句话念成语音（mp3）：用设置里选的模型，用不了就退回最稳定的多语言模型
    static func speak(_ text: String, voiceID: String) async throws -> Data {
        guard isConfigured else { throw Failure.noKey }
        var url = base.appending(path: "v1/text-to-speech/\(voiceID)")
        url.append(queryItems: [URLQueryItem(name: "output_format", value: "mp3_44100_128")])
        var lastError: Error = Failure.other("没有生成语音")
        let tries = model == fallbackModel ? [model] : [model, fallbackModel]
        for model in tries {
            var req = request(url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "text": text,
                "model_id": model,
                // 稍微放开稳定度、带一点风格：更像随口说话，而不是播音
                "voice_settings": ["stability": 0.45, "similarity_boost": 0.8, "style": 0.3, "use_speaker_boost": true],
            ])
            let (data, response) = try await URLSession.shared.data(for: req)
            do {
                try check(response, data)
                return data
            } catch Failure.other(let text) {
                // 这个模型用不了：换下一个
                lastError = Failure.other(text)
                continue
            }
        }
        throw lastError
    }

    private static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 40
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return req
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.other("没有收到回应") }
        guard !(200..<300).contains(http.statusCode) else { return }
        let message = String(data: data, encoding: .utf8) ?? ""
        if message.contains("quota") { throw Failure.quota }
        if http.statusCode == 401 { throw Failure.badKey }
        throw Failure.other("ElevenLabs 出错了（\(http.statusCode)）")
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
