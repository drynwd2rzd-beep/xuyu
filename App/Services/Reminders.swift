import Foundation
import SwiftData
import UserNotifications

/// 本地通知：待办提醒、每晚的日记、提前排好的主动消息。都不需要服务器推送。
enum Reminders {
    private static var center: UNUserNotificationCenter { .current() }

    static func ensureAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    private static func schedule(id: String, title: String, body: String, at date: Date,
                                 userInfo: [String: String] = [:], repeatsDaily: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        let cal = Calendar.current
        let comps = repeatsDaily
            ? cal.dateComponents([.hour, .minute], from: date)
            : cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: repeatsDaily)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger), withCompletionHandler: nil)
    }

    // MARK: - 待办

    /// 待办只提前排这么久以内要响的：iOS 最多只留 64 条还没响的本地通知，排得太远会把近处的挤掉（被系统悄悄丢掉）。
    /// 更远的等快到了再排（每次打开 App 都会补排一遍）
    private static let horizon = Limits.Timing.todoHorizon

    /// 打开 App 时：把所有没做完的待办重新排一遍，两周内要响的补上
    @MainActor
    static func syncTodos(_ context: ModelContext) {
        let items = (try? context.fetch(FetchDescriptor<TodoItem>(predicate: #Predicate { !$0.isDone }))) ?? []
        items.forEach(sync)
    }

    static func sync(_ item: TodoItem) {
        let id = "todo-" + item.id.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let enabled = UserDefaults.standard.object(forKey: Prefs.todoReminders) as? Bool ?? true
        guard enabled, item.remind, !item.isDone, let due = item.dueDate else { return }
        let fire = item.hasTime
            ? due.addingTimeInterval(-Double(item.remindLead) * 60)
            : Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: due) ?? due
        guard fire > .now, fire.timeIntervalSinceNow < horizon else { return }
        let body: String
        if item.hasTime {
            body = item.remindLead == 0 ? "现在该做这件事了" : "\(Fmt.hm.string(from: due)) 开始，还有 \(item.remindLead) 分钟"
        } else {
            body = "今天的待办"
        }
        schedule(id: id, title: item.title, body: body, at: fire, userInfo: ["tab": "todo"])
    }

    static func cancel(_ item: TodoItem) {
        center.removePendingNotificationRequests(withIdentifiers: ["todo-" + item.id.uuidString])
    }

    // MARK: - 日记

    static func syncDiaryReminder() {
        let id = "diary-nightly"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let enabled = UserDefaults.standard.object(forKey: Prefs.diaryReminder) as? Bool ?? true
        guard enabled else { return }
        let at = Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: .now) ?? .now
        schedule(id: id, title: "今天的日记", body: "来看看今天发生了什么，也写几句自己的吧。", at: at,
                 userInfo: ["tab": "todo"], repeatsDaily: true)
    }

    // MARK: - 主动消息

    static func scheduleProactive(messageID: UUID, conversationID: UUID, title: String, body: String, at date: Date) {
        schedule(id: "proactive-" + messageID.uuidString, title: title, body: body, at: date,
                 userInfo: ["conversation": conversationID.uuidString])
    }

    /// App 在后台时回复好了：马上发一条本地通知；免打扰时段里静悄悄地放进通知中心，不响不亮屏
    static func notifyReply(conversationID: UUID, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if Prefs.isQuiet(.now) {
            content.sound = nil
            content.interruptionLevel = .passive
        } else {
            content.sound = .default
        }
        content.userInfo = ["conversation": conversationID.uuidString]
        center.add(UNNotificationRequest(identifier: "reply-" + UUID().uuidString, content: content, trigger: nil),
                   withCompletionHandler: nil)
    }

    static func cancelProactive(messageID: UUID) {
        cancelProactive(messageIDs: [messageID])
    }

    static func cancelProactive(messageIDs: [UUID]) {
        guard !messageIDs.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: messageIDs.map { "proactive-" + $0.uuidString })
    }

    /// 清空、删掉的聊天：已经弹出来的通知也清掉，点了不会进到空的聊天或空白页
    static func removeDelivered(conversations ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let targets = Set(ids.map(\.uuidString))
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { list in
            let gone = list.filter { targets.contains($0.request.content.userInfo["conversation"] as? String ?? "") }
            center.removeDeliveredNotifications(withIdentifiers: gone.map(\.request.identifier))
        }
    }
}
