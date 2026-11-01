import Foundation

/// 通话内容：消息 ID → 每一句（中文 + 韩语），存在本机一个小文件里；删消息时一起删
enum CallLogs {
    static let shared = KeyedFileStore<[CallSession.Line]>(.calls)

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// 打电话的入口：通话记录里点「再打一次」时用
    static let callAgain = Notification.Name("xuyu.callAgain")
}

extension KeyedFileStore where Value == [CallSession.Line] {
    /// 这次通话说过的每一句
    func lines(_ id: UUID) -> [CallSession.Line] { value(id) ?? [] }
}
