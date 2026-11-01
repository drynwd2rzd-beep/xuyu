import SwiftUI

/// 聊天页和聊天列表的刷新时间表：每分钟走一次，另外在提前排好的消息（主动消息、追问、约定）到点的那一刻也走一次。
/// 这样通知弹出来时，点进聊天就已经能看到那句话，出现时也和别的气泡一样冒出来，不用等到下一个整分钟
struct PlannedSchedule: TimelineSchedule {
    let planned: [Date]

    init(_ convo: Conversation) {
        planned = convo.plannedMessages().map(\.createdAt)
    }

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var minute = Calendar.current.dateInterval(of: .minute, for: start)?.start ?? start
        var upcoming = planned.filter { $0 > start }.sorted()[...]
        var first = true
        return AnyIterator {
            if first {
                first = false
                return start
            }
            let next = minute.addingTimeInterval(60)
            if let due = upcoming.first, due < next {
                upcoming.removeFirst()
                return due
            }
            minute = next
            return next
        }
    }
}
