import SwiftUI
import SwiftData

/// 画册的待办页：很大的「做完几件 / 一共几件」，下面一句还剩几件，再下面就是今天的清单
/// （勾掉、写新的、长按推到明天都和以前一样，见 TodoCard）。清单长了在这一页里自己滚
struct TodoPage: View {
    let number: Int
    let total: Int
    @Query private var items: [TodoItem]

    var body: some View {
        let start = Date.now.startOfDay, end = start.adding(days: 1)
        let today = items.filter { item in
            if item.isDone { return (item.completedAt ?? .distantPast) >= start }
            return (item.dueDate ?? .distantPast) < end
        }
        let done = today.filter(\.isDone).count
        PhotobookPage(folio: String(localized: "待办　今天"), number: number, total: total) {
            Palette.card
        } content: {
            VStack(alignment: .leading, spacing: Space.group) {
                Spacer(minLength: Space.bookTop)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(verbatim: "\(done)")
                        .foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                    Text(verbatim: "/\(today.count)")
                        .foregroundStyle(Palette.faint)
                }
                .font(Typo.serif(Typo.Book.count, .light))
                .tracking(-Typo.labelTracking)
                .monospacedDigit()
                .animation(Motion.spring, value: done)
                .reveal()
                Text(hint(left: today.count - done))
                    .font(.system(size: Typo.caption))
                    .tracking(Typo.labelTracking)
                    .foregroundStyle(Palette.inkSoft)
                    .reveal(1)
                ScrollView {
                    TodoCard(day: start, plain: true)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .reveal(2)
            }
        }
    }

    private func hint(left: Int) -> String {
        left == 0 ? String(localized: "今天都做完了") : String(localized: "还剩 \(left) 件")
    }
}
