import Foundation
import os

extension RelayClient {
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
