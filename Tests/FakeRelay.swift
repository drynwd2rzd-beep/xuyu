import Foundation
@testable import Xuyu

/// 测试用的假中继：不连电脑，每次请求按事先写好的脚本吐事件（审查 Z-404）
@MainActor
final class FakeRelay: RelayTransport {
    var isConnected = true
    /// 每次 run 吐的事件，按顺序用掉；用完以后都只回一个「好」
    var scripts: [[RelayEvent]] = []
    /// 设了就让下一次 run 在吐完事件后出这个错
    var failure: Error?
    /// 收到过的请求（看 TA 这次看到了什么）
    private(set) var requests: [RelayRequest] = []
    /// 工作模式里替你回答过的确认
    private(set) var answered: [(req: String, ok: Bool)] = []

    func run(_ request: RelayRequest, id: String) -> AsyncThrowingStream<RelayEvent, Error> {
        requests.append(request)
        let events = scripts.isEmpty ? [.text("好")] : scripts.removeFirst()
        let failure = self.failure
        self.failure = nil
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
        }
    }

    func resume(_ id: String) -> AsyncThrowingStream<RelayEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func answer(_ req: String, ok: Bool) {
        answered.append((req, ok))
    }
}
