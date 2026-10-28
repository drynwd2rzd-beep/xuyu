import Foundation

/// MiniMax：声音、念、复刻、删除。官网能调的参数都接上了
enum MiniMax {
    static let models = ["speech-2.8-hd", "speech-2.8-turbo", "speech-2.6-hd", "speech-2.6-turbo",
                         "speech-02-hd", "speech-02-turbo", "speech-01-hd", "speech-01-turbo"]

    /// 国内版和国际版是两个平台，密钥不通用。国内版换过网址：先用新的，连不上再试旧的
    static var hosts: [String] {
        UserDefaults.standard.string(forKey: Prefs.minimaxRegion) == "global"
            ? ["https://api.minimax.io"]
            : ["https://api.minimax.cn", "https://api.minimaxi.com"]
    }

    static func post(_ path: String, json: [String: Any], timeout: TimeInterval = 40) async throws -> [String: Any] {
        try await send(path, contentType: "application/json", body: JSONSerialization.data(withJSONObject: json), timeout: timeout)
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

    /// 系统自带的、你复刻的、你用文字生成的声音（自己的排在前面）
    static func voices() async throws -> [Voice.Choice] {
        let root = try await post("v1/get_voice", json: ["voice_type": "all"])
        var list: [Voice.Choice] = []
        for (group, label) in [("voice_cloning", "复刻"), ("voice_generation", "生成"), ("system_voice", "")] {
            for v in root[group] as? [[String: Any]] ?? [] {
                guard let id = v["voice_id"] as? String else { continue }
                let notes = (v["description"] as? [String] ?? []).prefix(2).joined(separator: " · ")
                let created = v["created_time"] as? String ?? ""
                let detail = [String(localized: String.LocalizationValue(label)), notes, created].filter { !$0.isEmpty }.joined(separator: " · ")
                list.append(Voice.Choice(id: id, name: v["voice_name"] as? String ?? id, detail: detail, preview: nil,
                                         mine: group != "system_voice", kind: group == "system_voice" ? "" : group))
            }
        }
        return list
    }

    static func speak(_ text: String, persona: Persona, model: String) async throws -> Data {
        let style = persona.style
        var setting: [String: Any] = [
            "voice_id": persona.voiceID,
            "speed": min(2, max(0.5, persona.voiceSpeed)),
            "vol": min(10, max(0.1, persona.voiceVolume)),
            "pitch": min(12, max(-12, persona.voicePitch)),
        ]
        // 情绪：空 = 让模型按文字自己判断；耳语、平稳只有 2.6 模型支持
        let emotion = persona.voiceEmotion
        if !emotion.isEmpty && (!["whisper", "fluent"].contains(emotion) || model.hasPrefix("speech-2.6")) {
            setting["emotion"] = emotion
        }
        var json: [String: Any] = [
            "model": model,
            "text": text,
            "stream": false,
            "audio_setting": ["sample_rate": 32000, "bitrate": 128000, "format": "mp3", "channel": 1],
            "language_boost": style.languageBoost.isEmpty ? (persona.language == "ko" ? "Korean" : "Chinese") : style.languageBoost,
        ]
        // 混合声音：主声音和别的声音按比重混在一起（这时 voice_id 留空）
        let mixes = style.mixes.prefix(3).filter { $0.weight > 0 }
        if !mixes.isEmpty {
            setting["voice_id"] = ""
            let main: [String: Any] = ["voice_id": persona.voiceID, "weight": min(100, max(1, style.mainWeight))]
            json["timbre_weights"] = [main] + mixes.map { ["voice_id": $0.id, "weight": min(100, max(1, $0.weight))] as [String: Any] }
        }
        json["voice_setting"] = setting
        // 音色微调和音效
        var modify: [String: Any] = [:]
        if style.tonePitch != 0 { modify["pitch"] = style.tonePitch }
        if style.intensity != 0 { modify["intensity"] = style.intensity }
        if style.timbre != 0 { modify["timbre"] = style.timbre }
        if !style.effect.isEmpty { modify["sound_effects"] = style.effect }
        if !modify.isEmpty { json["voice_modify"] = modify }
        // 朗读优化：数字、符号读得更准
        if style.quality { json["text_normalization_mode"] = "quality" }
        // 读音纠正：「原文/读音」
        let tones = style.pronunciations.map(\.trimmed).filter { $0.contains("/") }
        if !tones.isEmpty { json["pronunciation_dict"] = ["tone": tones] }
        // 念一句话不该等太久：等不到就先发文字，不让「正在输入」一直挂着
        let root = try await post("v1/t2a_v2", json: json, timeout: 15)
        guard let hex = (root["data"] as? [String: Any])?["audio"] as? String, let audio = Data(hex: hex), !audio.isEmpty else {
            throw Voice.Failure.other("MiniMax 没有返回语音")
        }
        return audio
    }

    /// 把录音传上去，拿到文件编号。purpose：voice_clone（复刻用的录音）或 prompt_audio（参考录音）
    static func upload(_ audio: Data, purpose: String) async throws -> Int64 {
        var form = Multipart()
        form.field("purpose", purpose)
        form.file("file", fileName: "voice.m4a", mime: "audio/mp4", data: audio)
        let uploaded = try await send("v1/files/upload", contentType: form.contentType, body: form.finished(), timeout: 180)
        let file = uploaded["file"] as? [String: Any]
        guard let id = (file?["file_id"] as? NSNumber)?.int64Value ?? (file?["file_id"] as? String).flatMap({ Int64($0) }) else {
            throw Voice.Failure.other("录音没有传上去")
        }
        return id
    }

    /// 快速复刻。复刻这一步不收费；第一次用新声音念话时扣一次复刻费，7 天内不用会被删掉
    static func clone(_ r: Voice.CloneRequest) async throws -> String {
        let fileID = try await upload(r.audio, purpose: "voice_clone")
        // 新声音的 ID：字母开头、只有字母和数字
        let voiceID = "xuyu" + String((0..<12).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! })
        var json: [String: Any] = [
            "file_id": fileID,
            "voice_id": voiceID,
            "need_noise_reduction": r.denoise,
            "need_volume_normalization": r.normalize,
        ]
        if let reference = r.reference, !r.referenceText.trimmed.isEmpty {
            let promptID = try await upload(reference, purpose: "prompt_audio")
            var text = r.referenceText.trimmed
            // 原话要以标点结尾
            if let last = text.last, !"。！？.!?，,…~".contains(last) { text += "。" }
            json["clone_prompt"] = ["prompt_audio": promptID, "prompt_text": text]
        }
        if !r.languageBoost.isEmpty { json["language_boost"] = r.languageBoost }
        if !r.validation.trimmed.isEmpty {
            json["text_validation"] = String(r.validation.trimmed.prefix(200))
            json["accuracy"] = min(1, max(0.1, r.accuracy))
        }
        let result = try await post("v1/voice_clone", json: json)
        if let sensitive = result["input_sensitive"] as? [String: Any], sensitive["type"] as? Int ?? 0 != 0 {
            throw Voice.Failure.other("录音内容没有通过审核")
        }
        return voiceID
    }

    static func delete(_ id: String, kind: String) async throws {
        _ = try await post("v1/delete_voice", json: ["voice_type": kind, "voice_id": id])
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
        case 1002: throw Voice.Failure.other("请求太频繁，稍后再试")
        case 1043: throw Voice.Failure.other("录音和填写的原话对不上")
        case 2038: throw Voice.Failure.other("MiniMax 账号还没实名认证，不能复刻")
        case 2013: throw Voice.Failure.other("录音不符合要求：10 秒到 5 分钟，只有一个人说话")
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
