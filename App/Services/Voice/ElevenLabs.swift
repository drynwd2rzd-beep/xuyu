import Foundation

/// ElevenLabs：声音、模型、念、复刻、改名、删除
enum ElevenLabs {
    static let base = URL(string: "https://api.elevenlabs.io")!

    static func request(_ path: String, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: base.appending(path: path))
        req.timeoutInterval = 40
        req.httpMethod = method
        req.setValue(Voice.key(.elevenlabs), forHTTPHeaderField: "xi-api-key")
        return req
    }

    static func models() async throws -> [(id: String, name: String)] {
        let (data, response) = try await URLSession.shared.data(for: request("v1/models"))
        try check(response, data)
        let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return list.compactMap { m in
            guard let id = m["model_id"] as? String, m["can_do_text_to_speech"] as? Bool == true else { return nil }
            return (id, m["name"] as? String ?? id)
        }
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
            let category = v["category"] as? String ?? ""
            return Voice.Choice(id: id, name: v["name"] as? String ?? id,
                                detail: labels.prefix(3).joined(separator: " · "),
                                preview: (v["preview_url"] as? String).flatMap(URL.init(string:)),
                                mine: category == "cloned" || category == "generated")
        }
    }

    static func speak(_ text: String, persona: Persona, model: String) async throws -> Data {
        let style = persona.style
        var req = request("v1/text-to-speech/\(persona.voiceID)", method: "POST")
        // 念一句话不该等太久：等不到就先发文字，不让「正在输入」一直挂着
        req.timeoutInterval = 15
        req.url?.append(queryItems: [URLQueryItem(name: "output_format", value: "mp3_44100_128")])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var json: [String: Any] = [
            "text": text,
            "model_id": model,
            "voice_settings": [
                "stability": style.stability,
                "similarity_boost": style.similarity,
                "style": style.style,
                "use_speaker_boost": style.speakerBoost,
                // 语速只能 0.7～1.2
                "speed": min(1.2, max(0.7, persona.voiceSpeed)),
            ] as [String: Any],
        ]
        // 指定说哪种话（多语言 v2 不支持这一项）
        if !model.contains("multilingual_v2") { json["language_code"] = persona.lang.rawValue }
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
        return data
    }

    /// 即时复刻：录音、名字、描述，可以去除背景噪音
    static func clone(_ r: Voice.CloneRequest) async throws -> String {
        var form = Multipart()
        form.field("name", r.name)
        form.file("files", fileName: "voice.m4a", mime: "audio/mp4", data: r.audio)
        form.field("remove_background_noise", r.denoise ? "true" : "false")
        if !r.description.trimmed.isEmpty { form.field("description", r.description.trimmed) }
        var req = request("v1/voices/add", method: "POST")
        req.timeoutInterval = 180
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finished()
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = root?["voice_id"] as? String else { throw Voice.Failure.other("没有复刻成功") }
        return id
    }

    static func rename(_ id: String, to name: String) async throws {
        var form = Multipart()
        form.field("name", name)
        var req = request("v1/voices/\(id)/edit", method: "POST")
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finished()
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
    }

    static func delete(_ id: String) async throws {
        let (data, response) = try await URLSession.shared.data(for: request("v1/voices/\(id)", method: "DELETE"))
        try check(response, data)
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw Voice.Failure.other("没有收到回应") }
        guard !(200..<300).contains(http.statusCode) else { return }
        let message = String(data: data, encoding: .utf8) ?? ""
        if message.contains("quota") { throw Voice.Failure.quota }
        if http.statusCode == 401 { throw Voice.Failure.badKey }
        if message.contains("voice_limit") { throw Voice.Failure.other("ElevenLabs 的声音数量到上限了，先删掉一个") }
        throw Voice.Failure.other("ElevenLabs 出错了（\(http.statusCode)）")
    }
}
