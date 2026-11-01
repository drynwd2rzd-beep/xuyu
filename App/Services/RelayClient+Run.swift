import Foundation

// MARK: - 调用：发请求、取回中断的回复（RelayTransport）

extension RelayClient {
    /// 没连上就先连，最多等 8 秒
    private func waitUntilConnected() async throws {
        connectIfConfigured()
        if state == .connected { return }
        if case .notConfigured = state { throw RelayError.notConfigured }
        // 最多等 8 秒：连上了、连接失败了、或者到点了，谁先到就按谁收尾（每个等待只会被收尾一次）。
        // 以前用任务组做超时：组要等所有子任务结束，而等连接的那个不响应取消，8 秒到了也走不掉，
        // 要一直等到下一次重连失败（最长 30 多秒），电脑没开时发出去的消息很久才报错
        let token = UUID()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            waiters[token] = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.waiters.removeValue(forKey: token)?.resume(throwing: RelayError.unreachable)
            }
        }
    }

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

    /// 发一次请求，边写边收（不带 id 的写法在 RelayTransport 里）
    func run(_ request: RelayRequest, id: String) -> AsyncThrowingStream<RelayEvent, Error> {
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
}
