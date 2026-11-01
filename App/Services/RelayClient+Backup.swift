import Foundation

// MARK: - 备份（存到电脑 / 从电脑取回）

extension RelayClient {
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

    // 大的备份分块传：整个塞进一条消息的话，照片多了以后会超过中继一条消息 64MB 的上限，连接被直接断掉、备份悄悄失败。
    // 8MB 以下还是一条消息发完（旧版中继也认）；更大的每块 4MB，一块一块等电脑说「收到」再发下一块。
    // 转成 base64 文字在后台做，不卡界面
    private static let singleMessageLimit = 8 * 1024 * 1024
    private static let chunkSize = 4 * 1024 * 1024

    private nonisolated static func base64(_ data: Data) async -> String {
        await Task.detached(priority: .utility) { data.base64EncodedString() }.value
    }

    private nonisolated static func unbase64(_ text: String) async -> Data? {
        await Task.detached(priority: .utility) { Data(base64Encoded: text) }.value
    }

    func saveBackup(name: String, data: Data) async -> Bool {
        transfers += 1
        defer { transfers -= 1 }
        if data.count <= Self.singleMessageLimit {
            let encoded = await Self.base64(data)
            let reply = await ask(["type": "backup", "name": name, "data": encoded], wait: Self.wait(forBytes: data.count))
            return reply["ok"] as? Bool == true
        }
        let total = (data.count + Self.chunkSize - 1) / Self.chunkSize
        for index in 0..<total {
            let start = index * Self.chunkSize
            let piece = data.subdata(in: start..<min(data.count, start + Self.chunkSize))
            let encoded = await Self.base64(piece)
            let reply = await ask(["type": "backupChunk", "name": name, "index": index, "total": total, "data": encoded],
                                  wait: Self.wait(forBytes: piece.count))
            guard reply["ok"] as? Bool == true else { return false }
        }
        return true
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
        if backup.size <= Self.singleMessageLimit {
            let reply = await ask(["type": "fetchBackup", "name": backup.name], wait: Self.wait(forBytes: backup.size))
            guard let text = reply["data"] as? String else { return nil }
            return await Self.unbase64(text)
        }
        // 大的备份一块一块取回来再拼上；电脑每次告诉我们文件一共多大
        var result = Data()
        result.reserveCapacity(backup.size)
        var size = backup.size
        while result.count < size {
            let reply = await ask(["type": "fetchBackupChunk", "name": backup.name, "offset": result.count, "length": Self.chunkSize],
                                  wait: Self.wait(forBytes: Self.chunkSize))
            guard let text = reply["data"] as? String, let piece = await Self.unbase64(text), !piece.isEmpty else { return nil }
            result.append(piece)
            size = reply["size"] as? Int ?? size
        }
        return result
    }
}
