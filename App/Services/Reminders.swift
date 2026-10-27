import Foundation
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

    static func sync(_ item: TodoItem) {
        let id = "todo-" + item.id.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let enabled = UserDefaults.standard.object(forKey: Prefs.todoReminders) as? Bool ?? true
        guard enabled, item.remind, !item.isDone, let due = item.dueDate else { return }
        let fire = item.hasTime
            ? due.addingTimeInterval(-Double(item.remindLead) * 60)
            : Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: due) ?? due
        guard fire > .now else { return }
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
        guard UserDefaults.standard.object(forKey: Prefs.inAppBanner) as? Bool ?? true else { return }
        schedule(id: "proactive-" + messageID.uuidString, title: title, body: body, at: date,
                 userInfo: ["conversation": conversationID.uuidString])
    }

    static func cancelProactive(messageID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: ["proactive-" + messageID.uuidString])
    }
}
