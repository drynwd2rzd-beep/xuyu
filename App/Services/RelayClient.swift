import Foundation
import CryptoKit
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
    // MARK: 给扩展用的（RelayClient+Run、+Backup），别处不要碰
    /// 正在收的回复：id → 往外吐事件的口子
    @ObservationIgnored var streams: [String: AsyncThrowingStream<RelayEvent, Error>.Continuation] = [:]
    /// 每条回复已经收到的片段数；断线重连后从这里接着收
    @ObservationIgnored var received: [String: Int] = [:]
    /// 在等连上的请求（连上、失败或 8 秒到了收尾）
    @ObservationIgnored var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// 正在传的大备份有几份（传的时候心跳暂停检查）
    @ObservationIgnored var transfers = 0
    /// 备份相关的请求在等电脑按同一个 id 回复
    @ObservationIgnored var replies: [String: CheckedContinuation<[String: Any], Never>] = [:]
    // MARK: 连接
    @ObservationIgnored private var orphanTimeout: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: Double = 2
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private let session = URLSession(configuration: .default)
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var lastPath = ""
    @ObservationIgnored private var onWiFi = true
    // MARK: 对暗号（RelayPairing）
    /// 这条连接已经和中继互相对上暗号：之前什么都不发，也不认中继发来的别的消息
    @ObservationIgnored private var verified = false
    /// 这条连接收到过中继的 hello（没收到就被关掉，说明电脑上还是旧版中继）
    @ObservationIgnored private var sawHello = false
    @ObservationIgnored private var serverNonce = ""
    @ObservationIgnored private var clientNonce = ""
    /// 配对码拉伸出的钥匙：算一次要几十毫秒，按配对码记住
    @ObservationIgnored private var pairKey: (code: String, key: SymmetricKey)?

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
        get { Keychain.get(Keychain.Account.relayCode) ?? "" }
        set { Keychain.set(newValue.trimmed.uppercased(), for: Keychain.Account.relayCode) }
    }

    var isConnected: Bool { state == .connected }

    /// 连上电脑了（断开后重新连上也算）：排着队没回的消息这时再回
    static let didConnect = Notification.Name("relay.didConnect")

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
        guard !list.isEmpty, !code.trimmed.isEmpty, let url = Self.url(address: list[candidateIndex]) else {
            state = .notConfigured
            return
        }
        usingAway = list[candidateIndex] == awayAddress && !awayAddress.isEmpty
        retryTask?.cancel()
        state = .connecting
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        verified = false
        sawHello = false
        task.resume()
        receive(on: task)
        // 先等中继的 hello，对上暗号以后再要状态（answerHello、checkWelcome）
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

    /// 中继的地址。配对码不放进网址（以前放在这里，同一个网络里的人能看到），改成连上后对暗号
    static func url(address: String) -> URL? {
        var host = address.trimmed
        guard !host.isEmpty else { return nil }
        for prefix in ["ws://", "wss://", "http://", "https://"] where host.lowercased().hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
        }
        while host.hasSuffix("/") { host.removeLast() }
        if !host.contains(":") { host += ":51888" }
        return URLComponents(string: "ws://\(host)/ws")?.url
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
                    // 没等到 hello 就被关掉：是旧版中继在拒绝没带配对码的网址
                    case 4001 where !self.sawHello: Self.relayTooOld
                    case 4001: "配对码不对"
                    case 4002: Self.relayTooOld
                    case 4003: "配对码输错太多次，请 15 分钟后再试"
                    case 4004: "这条线路不安全，中继没有接受"
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
            try? await Task.sleep(for: Limits.Timing.orphanReply)
            guard !Task.isCancelled, let self, self.state != .connected else { return }
            self.failStreams(RelayError.unreachable)
        }
        waiters.values.forEach { $0.resume(throwing: RelayError.unreachable) }
        waiters = [:]
        // 配对码错误、中继太旧时不自动重连：重连也一样，要你先处理
        guard !reason.contains("配对码"), reason != Self.relayTooOld else { return }
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
        // 对上暗号以前，只认 hello 和 welcome
        guard verified else {
            if type == "hello" { answerHello(obj) }
            if type == "welcome" { checkWelcome(obj) }
            return
        }
        let id = obj["id"] as? String ?? ""
        // 备份相关的请求：按 id 交还给等待的地方
        if ["backupSaved", "backups", "backupData", "backupChunkSaved", "backupChunkData"].contains(type) {
            replies.removeValue(forKey: id)?.resume(returning: obj)
            return
        }
        switch type {
        case "status":
            if let decoded = try? JSONDecoder().decode(RelayStatus.self, from: data) { status = decoded }
            if state != .connected {
                state = .connected
                NotificationCenter.default.post(name: Self.didConnect, object: nil)
                retryDelay = 2
                orphanTimeout?.cancel()
                waiters.values.forEach { $0.resume() }
                waiters = [:]
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
        case "approve":
            // 不带编号：断线重连后中继会再问一次，同一个 req 由聊天引擎去重
            if let req = obj["req"] as? String {
                streams[id]?.yield(.approval(req: req, text: obj["text"] as? String ?? ""))
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

    /// 发给中继。对上暗号以前什么都不发：对方可能是冒充的，而且中继也只认 auth
    func sendJSON(_ object: Any) {
        guard verified else { return }
        send(object)
    }

    private func send(_ object: Any) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    // MARK: - 对暗号

    /// 电脑上还是旧版中继（还在用网址里带配对码的连接方式）
    static let relayTooOld = "电脑上的中继需要更新：重启一下中继再试"

    /// 中继发来 hello：出一个自己的随机数，连同手机的证明发回去
    private func answerHello(_ obj: [String: Any]) {
        guard let task, !sawHello, let nonce = obj["nonce"] as? String, RelayPairing.validNonce(nonce) else { return }
        sawHello = true
        let cnonce = RelayPairing.newNonce()
        serverNonce = nonce
        clientNonce = cnonce
        let code = self.code
        Task { [weak self] in
            guard let self, let key = await self.pairingKey(for: code), self.task === task else { return }
            self.send(["type": "auth", "cnonce": cnonce,
                       "proof": RelayPairing.proof(key: key, role: "app", nonce: nonce, cnonce: cnonce)])
        }
    }

    /// 中继回 welcome：核对它的证明。对不上说明对方不知道配对码，不是你的中继，换下一个地址
    private func checkWelcome(_ obj: [String: Any]) {
        guard let task else { return }
        guard let key = pairKey?.key, let proof = obj["proof"] as? String,
              RelayPairing.same(proof, RelayPairing.proof(key: key, role: "relay", nonce: serverNonce, cnonce: clientNonce)) else {
            fail(task, reason: "对方不是你的电脑中继")
            return
        }
        verified = true
        sendJSON(["type": "status", "id": "hello"])
    }

    /// 配对码拉伸出的钥匙：第一次在后台算，之后直接用
    private func pairingKey(for code: String) async -> SymmetricKey? {
        if let cached = pairKey, cached.code == code { return cached.key }
        let key = await Task.detached(priority: .userInitiated) { RelayPairing.key(for: code) }.value
        if let key { pairKey = (code, key) }
        return key
    }

    /// 你对工作模式里那一步的回答
    func answer(_ req: String, ok: Bool) {
        sendJSON(["type": "approval", "req": req, "ok": ok])
    }

    func refreshStatus() {
        sendJSON(["type": "status", "id": UUID().uuidString])
    }

    /// 让电脑开机时自动启动（或不再自动启动）中继；电脑回复新的状态
    func setAutostart(_ on: Bool) {
        sendJSON(["type": "autostart", "id": UUID().uuidString, "on": on])
    }
}
