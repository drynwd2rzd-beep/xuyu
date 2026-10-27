import Foundation
import Observation

struct EngineStatus: Decodable, Equatable {
    var installed: Bool
    var version: String
}

struct RelayStatus: Decodable, Equatable {
    struct Models: Decodable, Equatable {
        var claude: [String]
        var codex: [String]
    }
    var host: String
    var claude: EngineStatus
    var codex: EngineStatus
    var models: Models
}

struct RelayAttachment: Encodable {
    var kind: String
    var name: String
    var data: String
}

struct RelayRequest: Encodable {
    var engine: String
    var model: String
    var system: String
    var prompt: String
    var attachments: [RelayAttachment] = []
}

enum RelayEvent {
    case text(String)
    case reasoning(String)
}

enum RelayError: LocalizedError {
    case notConfigured
    case unreachable
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "还没有连接电脑。去「设置 → 连接」填写地址和配对码。"
        case .unreachable: "连不上电脑上的中继。请确认电脑开着中继窗口，并且和手机在同一个网络。"
        case .server(let message): message
        }
    }
}

/// 和电脑上「絮语中继」之间的 WebSocket 连接
@MainActor
@Observable
final class RelayClient {
    enum State: Equatable {
        case notConfigured, connecting, connected, failed(String)
    }

    private(set) var state: State = .notConfigured
    private(set) var status: RelayStatus?

    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var streams: [String: AsyncThrowingStream<RelayEvent, Error>.Continuation] = [:]
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Error>] = []
    @ObservationIgnored private var retryDelay: Double = 2
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private let session = URLSession(configuration: .default)

    var address: String {
        get { UserDefaults.standard.string(forKey: Prefs.relayAddress) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmed, forKey: Prefs.relayAddress) }
    }

    var code: String {
        get { Keychain.get("relayCode") ?? "" }
        set { Keychain.set(newValue.trimmed.uppercased(), for: "relayCode") }
    }

    var isConnected: Bool { state == .connected }

    // MARK: - 连接

    func connectIfConfigured() {
        if DemoMode.isOn {
            state = .connected
            status = RelayStatus(host: "UP-PC", claude: .init(installed: true, version: "2.4.0"),
                                 codex: .init(installed: true, version: "0.98.0"),
                                 models: .init(claude: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"], codex: []))
            return
        }
        switch state {
        case .connected, .connecting: return
        default: connect()
        }
    }

    func reconnect() {
        disconnect()
        connect()
    }

    private func connect() {
        guard let url = Self.url(address: address, code: code) else {
            state = .notConfigured
            return
        }
        retryTask?.cancel()
        state = .connecting
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        task.resume()
        receive(on: task)
        sendJSON(["type": "status", "id": "hello"])
        // 5 秒内没有拿到状态就算失败
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.task === task, self.state == .connecting else { return }
            self.fail(task, reason: "连接超时")
        }
    }

    private func disconnect() {
        retryTask?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failStreams(RelayError.unreachable)
        state = address.isEmpty ? .notConfigured : .failed("已断开")
    }

    static func url(address: String, code: String) -> URL? {
        var host = address.trimmed
        guard !host.isEmpty, !code.trimmed.isEmpty else { return nil }
        for prefix in ["ws://", "wss://", "http://", "https://"] where host.lowercased().hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
        }
        while host.hasSuffix("/") { host.removeLast() }
        if !host.contains(":") { host += ":51888" }
        var comps = URLComponents(string: "ws://\(host)/ws")
        comps?.queryItems = [URLQueryItem(name: "token", value: code.trimmed.uppercased())]
        return comps?.url
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(text)
                    case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                    self.receive(on: task)
                case .failure(let error):
                    let code = task.closeCode
                    self.fail(task, reason: code.rawValue == 4001 ? "配对码不对" : error.localizedDescription)
                }
            }
        }
    }

    private func fail(_ failed: URLSessionWebSocketTask, reason: String) {
        guard task === failed else { return }
        task = nil
        pingTask?.cancel()
        failed.cancel(with: .goingAway, reason: nil)
        state = .failed(reason)
        failStreams(RelayError.unreachable)
        waiters.forEach { $0.resume(throwing: RelayError.unreachable) }
        waiters = []
        // 配对码错误时不自动重连
        guard reason != "配对码不对" else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func failStreams(_ error: Error) {
        streams.values.forEach { $0.finish(throwing: error) }
        streams = [:]
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        let id = obj["id"] as? String ?? ""
        switch type {
        case "status":
            if let decoded = try? JSONDecoder().decode(RelayStatus.self, from: data) { status = decoded }
            if state != .connected {
                state = .connected
                retryDelay = 2
                waiters.forEach { $0.resume() }
                waiters = []
                startPing()
            }
        case "text":
            streams[id]?.yield(.text(obj["text"] as? String ?? ""))
        case "reasoning":
            streams[id]?.yield(.reasoning(obj["text"] as? String ?? ""))
        case "done":
            streams.removeValue(forKey: id)?.finish()
        case "error":
            streams.removeValue(forKey: id)?.finish(throwing: RelayError.server(obj["message"] as? String ?? "出错了"))
        default:
            break
        }
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, let task = self.task else { return }
                task.sendPing { _ in }
            }
        }
    }

    private func sendJSON(_ object: Any) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    func refreshStatus() {
        sendJSON(["type": "status", "id": UUID().uuidString])
    }

    private func waitUntilConnected() async throws {
        connectIfConfigured()
        if state == .connected { return }
        if case .notConfigured = state { throw RelayError.notConfigured }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    self.waiters.append(c)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw RelayError.unreachable
            }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - 调用

    func run(_ request: RelayRequest) -> AsyncThrowingStream<RelayEvent, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID().uuidString
            let work = Task { @MainActor in
                do {
                    try await self.waitUntilConnected()
                    self.streams[id] = continuation
                    var payload: [String: Any] = [
                        "type": "run", "id": id, "engine": request.engine, "model": request.model,
                        "system": request.system, "prompt": request.prompt,
                    ]
                    if !request.attachments.isEmpty {
                        payload["attachments"] = request.attachments.map { ["kind": $0.kind, "name": $0.name, "data": $0.data] }
                    }
                    self.sendJSON(payload)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                work.cancel()
                if case .cancelled = reason {
                    Task { @MainActor in
                        self.streams.removeValue(forKey: id)
                        self.sendJSON(["type": "cancel", "id": id])
                    }
                }
            }
        }
    }

    /// 一次性请求：等完整回复
    func complete(_ request: RelayRequest) async throws -> String {
        var text = ""
        for try await event in run(request) {
            if case .text(let t) = event { text += t }
        }
        return text.trimmed
    }
}
