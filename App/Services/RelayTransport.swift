import Foundation
import os

/// 回复引擎用到的中继能力：真的 `RelayClient` 实现它，测试里放一个按脚本吐事件的假中继（审查 Z-404）。
/// 聊天引擎、晚回、补一句、记忆整理、约定只认这个协议，不认具体的连接
@MainActor
protocol RelayTransport: AnyObject {
    var isConnected: Bool { get }
    /// 发一次请求，边写边收；id 用来断线后接着收、取消
    func run(_ request: RelayRequest, id: String) -> AsyncThrowingStream<RelayEvent, Error>
    /// 取回一条之前的回复（从头开始收）
    func resume(_ id: String) -> AsyncThrowingStream<RelayEvent, Error>
    /// 你对工作模式里那一步的回答
    func answer(_ req: String, ok: Bool)
}

extension RelayTransport {
    func run(_ request: RelayRequest) -> AsyncThrowingStream<RelayEvent, Error> {
        run(request, id: UUID().uuidString)
    }

    /// 一次性请求：等完整回复
    func complete(_ request: RelayRequest) async throws -> String {
        var text = ""
        for try await event in run(request) {
            if case .text(let t) = event { text += t }
        }
        return text.trimmed
    }

    /// 自己动起来的事（主动消息、追问、日记、动态、视频分享、世界安排…）用的请求：
    /// 失败了不打扰你（下次刷新再来），但在日志里记一笔为什么，方便查「TA 怎么没来找我」（ERR-4）。
    /// what：哪一件事，比如「主动消息」；只写事情的名字，不写提示词和回复
    func attempt(_ request: RelayRequest, _ what: String) async -> String? {
        do {
            return try await complete(request)
        } catch is CancellationError {
            return nil
        } catch {
            Log.auto.error("\(what, privacy: .public)没有成功：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

extension RelayClient: RelayTransport {}
