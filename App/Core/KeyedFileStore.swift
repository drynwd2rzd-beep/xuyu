import Foundation
import Observation

/// 按消息 ID 存的小数据（心声、视频卡片、通话内容）：整份放在内存里，改一条就把整份原子写回一个 JSON 文件。
/// 文件格式就是 `[UUID: Value]` 直接编码，和以前各自写的那几份一样，旧文件照样读得出来。
/// 删消息、清空聊天、删角色时由 Cleanup 调 remove 一起删掉，不会只增不减（DATA-8）
@Observable
final class KeyedFileStore<Value: Codable> {
    private(set) var values: [UUID: Value] = [:]
    let file: Storage.File

    init(_ file: Storage.File) {
        self.file = file
        reload()
    }

    /// 从文件读（打开时、从备份恢复后、恢复出厂后）
    func reload() {
        values = Storage.read([UUID: Value].self, from: file) ?? [:]
    }

    func value(_ id: UUID) -> Value? { values[id] }

    var count: Int { values.count }

    func set(_ value: Value, for id: UUID) {
        values[id] = value
        save()
    }

    /// 这些消息被删了：对应的条目一起删
    func remove(_ ids: some Sequence<UUID>) {
        var changed = false
        for id in ids where values.removeValue(forKey: id) != nil { changed = true }
        if changed { save() }
    }

    /// 只留这些 ID（超过上限时按消息先后挑出要留的）
    func keep(only ids: Set<UUID>) {
        let kept = values.filter { ids.contains($0.key) }
        guard kept.count != values.count else { return }
        values = kept
        save()
    }

    func clear() {
        values = [:]
        Storage.remove(file)
    }

    private func save() {
        Storage.write(values, to: file)
    }
}
