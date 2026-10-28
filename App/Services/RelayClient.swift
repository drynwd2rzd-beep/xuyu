import Foundation
import Network
import Observation

@MainActor
private final class PongFlag {
    var answered = false
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
    /// 每条回复已经收到的片段数；断线重连后从这里接着收
    @ObservationIgnored private var received: [String: Int] = [:]
    @ObservationIgnored private var orphanTimeout: Task<Void, Never>?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Error>] = []
    @ObservationIgnored private var retryDelay: Double = 2
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    /// 正在传的大备份有几份（传的时候心跳暂停检查）
    @ObservationIgnored private var transfers = 0
    @ObservationIgnored private let session = URLSession(configuration: .default)
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var lastPath = ""
    @ObservationIgnored private var onWiFi = true

    init() {
        // Wi-Fi ↔ 流量切换时，旧连接多半已经失效，但系统要很久才报错；这里一发现网络变了就立刻重连
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            let key = "\(path.status == .satisfied)-\(wifi)"
            Task { @MainActor in self?.networkChanged(key: key, wifi: wifi) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "xuyu.relay.path"))
    }

    private func networkChanged(key: String, wifi: Bool) {
        let first = lastPath.isEmpty
        onWiFi = wifi
        guard key != lastPath else { return }
        lastPath = key
        guard !first, !DemoMode.isOn, !candidates.isEmpty else { return }
        if let old = task {
            task = nil
            pingTask?.cancel()
            old.cancel(with: .goingAway, reason: nil)
        }
        // 正在收的回复不判失败，重连后接着收
        retryTask?.cancel()
        retryDelay = 2
        candidateIndex = 0
        connect()
    }

    /// 在家用的局域网地址
    var address: String {
        get { UserDefaults.standard.string(forKey: Prefs.relayAddress) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmed, forKey: Prefs.relayAddress) }
    }

    /// 出门用的地址（Tailscale），家里连不上时自动换它
    var awayAddress: String {
        get { UserDefaults.standard.string(forKey: Prefs.relayAddressAway) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmed, forKey: Prefs.relayAddressAway) }
    }

    /// 当前用的是哪个地址
    private(set) var usingAway = false
    @ObservationIgnored private var candidateIndex = 0

    /// 用 Wi-Fi 时先试家里的地址；用流量时家里的地址肯定连不上，直接先走出门线路
    private var candidates: [String] {
        let list = onWiFi ? [address, awayAddress] : [awayAddress, address]
        return list.filter { !$0.trimmed.isEmpty }
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
                                 models: .init(claude: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"], codex: ["gpt-6.1-sol"]),
                                 catalog: nil)
            return
        }
        switch state {
        case .connected, .connecting: return
        default: connect()
        }
    }

    /// 回到前台：旧连接可能已经被系统断掉，马上确认一下，断了就立刻重连（不等退避）
    func wake() {
        guard !DemoMode.isOn else { return }
        switch state {
        case .connected:
            guard let task else { return }
            task.sendPing { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in self?.fail(task, reason: "连接中断") }
            }
        case .connecting:
            return
        default:
            retryDelay = 2
            candidateIndex = 0
            connect()
        }
    }

    func reconnect() {
        disconnect()
        candidateIndex = 0
        connect()
    }

    private func connect() {
        let list = candidates
        if candidateIndex >= list.count { candidateIndex = 0 }
        guard !list.isEmpty, let url = Self.url(address: list[candidateIndex], code: code) else {
            state = .notConfigured
            return
        }
        usingAway = list[candidateIndex] == awayAddress && !awayAddress.isEmpty
        retryTask?.cancel()
        state = .connecting
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        task.resume()
        receive(on: task)
        sendJSON(["type": "status", "id": "hello"])
        // 出门线路可能要绕中转服务器，延迟高，多等一会儿
        let patience: Double = usingAway ? 15 : 6
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(patience))
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
        state = candidates.isEmpty ? .notConfigured : .failed("已断开")
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
                    let reason = switch code.rawValue {
                    case 4001: "配对码不对"
                    case 4003: "配对码输错太多次，请 15 分钟后再试"
                    default: Self.describe(error)
                    }
                    self.fail(task, reason: reason)
                }
            }
        }
    }

    /// 把系统的网络错误翻成简短的中文
    static func describe(_ error: Error) -> String {
        guard let e = error as? URLError else { return "连接中断" }
        switch e.code {
        case .notConnectedToInternet, .dataNotAllowed: return "手机没有网络"
        case .timedOut: return "连接超时"
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return "找不到电脑，确认中继开着"
        case .networkConnectionLost: return "网络断了"
        case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed: return "系统拦截了连接"
        case .badServerResponse: return "地址不对，或者中继没开"
        default: return "连接中断"
        }
    }

    private func fail(_ failed: URLSessionWebSocketTask, reason: String) {
        guard task === failed else { return }
        task = nil
        pingTask?.cancel()
        failed.cancel(with: .goingAway, reason: nil)
        state = .failed(reason)
        // 正在进行的回复先不判失败：电脑上还在继续生成，重新连上后会接着收。90 秒还连不上才算失败。
        orphanTimeout?.cancel()
        orphanTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled, let self, self.state != .connected else { return }
            self.failStreams(RelayError.unreachable)
        }
        waiters.forEach { $0.resume(throwing: RelayError.unreachable) }
        waiters = []
        // 配对码错误时不自动重连
        guard !reason.contains("配对码") else { return }
        // 还有别的地址（比如出门用的）就马上试下一个
        if candidateIndex + 1 < candidates.count {
            candidateIndex += 1
            connect()
            return
        }
        candidateIndex = 0
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
        received = [:]
    }

    /// 只接受比已收到的更新的片段（重连补发时去重）
    private func accept(_ id: String, _ obj: [String: Any]) -> Bool {
        guard let seq = obj["seq"] as? Int else { return true }
        if seq <= received[id, default: 0] { return false }
        received[id] = seq
        return true
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        let id = obj["id"] as? String ?? ""
        // 备份相关的请求：按 id 交还给等待的地方
        if ["backupSaved", "backups", "backupData"].contains(type) {
            replies.removeValue(forKey: id)?.resume(returning: obj)
            return
        }
        switch type {
        case "status":
            if let decoded = try? JSONDecoder().decode(RelayStatus.self, from: data) { status = decoded }
            if state != .connected {
                state = .connected
                retryDelay = 2
                orphanTimeout?.cancel()
                waiters.forEach { $0.resume() }
                waiters = []
                startPing()
                // 断线前没收完的回复，接着收
                for streamID in streams.keys {
                    sendJSON(["type": "resume", "id": streamID, "from": received[streamID, default: 0]])
                }
            }
        case "text":
            if accept(id, obj) { streams[id]?.yield(.text(obj["text"] as? String ?? "")) }
        case "reasoning":
            if accept(id, obj) { streams[id]?.yield(.reasoning(obj["text"] as? String ?? "")) }
        case "step":
            if accept(id, obj) { streams[id]?.yield(.step(obj["text"] as? String ?? "")) }
        case "file":
            if accept(id, obj), let name = obj["name"] as? String,
               let data = Data(base64Encoded: obj["data"] as? String ?? "") {
                streams[id]?.yield(.file(name, data))
            }
        case "done":
            received.removeValue(forKey: id)
            streams.removeValue(forKey: id)?.finish()
        case "error":
            received.removeValue(forKey: id)
            streams.removeValue(forKey: id)?.finish(throwing: RelayError.server(obj["message"] as? String ?? "出错了"))
        default:
            break
        }
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, let task = self.task else { return }
                // 正在传大的备份：心跳排在它后面，回音会晚，这时不检查，免得把正在传的连接当成断了
                guard self.transfers == 0 else { continue }
                // ping 不通、或者 10 秒没回音，就说明连接已经断了：马上换线路重连，而不是一直往死连接里发
                let pong = PongFlag()
                task.sendPing { [weak self] error in
                    Task { @MainActor in
                        pong.answered = true
                        if error != nil { self?.fail(task, reason: "连接中断") }
                    }
                }
                try? await Task.sleep(for: .seconds(10))
                if !pong.answered, self.task === task, self.transfers == 0 { self.fail(task, reason: "连接中断") }
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

    /// 让电脑开机时自动启动（或不再自动启动）中继；电脑回复新的状态
    func setAutostart(_ on: Bool) {
        sendJSON(["type": "autostart", "id": UUID().uuidString, "on": on])
    }

    // MARK: - 备份（存到电脑 / 从电脑取回）

    @ObservationIgnored private var replies: [String: CheckedContinuation<[String: Any], Never>] = [:]

    /// 发一个请求，等电脑按同一个 id 回复；等太久就当没回应。大的备份按大小多给时间，出门线路慢也够
    private func ask(_ payload: [String: Any], wait: Duration = .seconds(60)) async -> [String: Any] {
        guard isConnected else { return [:] }
        let id = UUID().uuidString
        var body = payload
        body["id"] = id
        return await withCheckedContinuation { c in
            replies[id] = c
            sendJSON(body)
            Task { @MainActor in
                try? await Task.sleep(for: wait)
                self.replies.removeValue(forKey: id)?.resume(returning: [:])
            }
        }
    }

    /// 传备份时等多久：每 MB 多等 15 秒
    private static func wait(forBytes bytes: Int) -> Duration {
        .seconds(60 + bytes / (1024 * 1024) * 15)
    }

    func saveBackup(name: String, data: Data) async -> Bool {
        transfers += 1
        defer { transfers -= 1 }
        let reply = await ask(["type": "backup", "name": name, "data": data.base64EncodedString()],
                              wait: Self.wait(forBytes: data.count))
        return reply["ok"] as? Bool == true
    }

    struct BackupInfo: Identifiable, Hashable {
        let name: String
        let size: Int
        let at: Date
        var id: String { name }
    }

    func listBackups() async -> [BackupInfo] {
        let reply = await ask(["type": "backups"])
        let list = reply["list"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return BackupInfo(name: name, size: item["size"] as? Int ?? 0,
                              at: Date(timeIntervalSince1970: (item["at"] as? Double ?? 0) / 1000))
        }
    }

    func fetchBackup(_ backup: BackupInfo) async -> Data? {
        transfers += 1
        defer { transfers -= 1 }
        let reply = await ask(["type": "fetchBackup", "name": backup.name], wait: Self.wait(forBytes: backup.size))
        return (reply["data"] as? String).flatMap { Data(base64Encoded: $0) }
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

    /// 取回一条之前的回复（从头开始收）：App 被关掉期间电脑上写好的内容
    func resume(_ id: String) -> AsyncThrowingStream<RelayEvent, Error> {
        AsyncThrowingStream { continuation in
            let work = Task { @MainActor in
                do {
                    try await self.waitUntilConnected()
                    self.streams[id] = continuation
                    self.received[id] = 0
                    self.sendJSON(["type": "resume", "id": id, "from": 0])
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                work.cancel()
                Task { @MainActor in self.streams.removeValue(forKey: id) }
            }
        }
    }

    func run(_ request: RelayRequest, id: String = UUID().uuidString) -> AsyncThrowingStream<RelayEvent, Error> {
        AsyncThrowingStream { continuation in
            let work = Task { @MainActor in
                do {
                    try await self.waitUntilConnected()
                    self.streams[id] = continuation
                    var payload: [String: Any] = [
                        "type": "run", "id": id, "engine": request.engine, "model": request.model,
                        "effort": request.effort, "system": request.system, "prompt": request.prompt,
                        "work": request.work,
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
