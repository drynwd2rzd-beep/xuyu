import SwiftUI
import SwiftData

/// 画册的日记页：一个很大的浅色日期，下面是 TA 最近一篇日记（宋体，首行缩进两个字），落款是写它的人。
/// 正在写今天的日记时，落款处说一声
struct DiaryPage: View {
    let entry: DiaryEntry
    let author: String
    let number: Int
    let total: Int
    private static let maxLines = 12

    var body: some View {
        PhotobookPage(folio: String(localized: "日记"), number: number, total: total) {
            Palette.paper
        } content: {
            VStack(alignment: .leading, spacing: Space.group) {
                HStack(alignment: .firstTextBaseline, spacing: Space.item) {
                    Text(verbatim: Fmt.enMonthDayShort.string(from: entry.day))
                        .font(Typo.serif(Typo.Book.date, .light).italic())
                        .foregroundStyle(Palette.faint)
                    if !entry.mood.isEmpty {
                        Text(verbatim: entry.mood)
                            .font(.system(size: Typo.label))
                            .tracking(Typo.labelTracking)
                            .foregroundStyle(Palette.inkSoft)
                    }
                }
                .reveal()
                Spacer(minLength: 0)
                // 首行缩进两个字：前面垫两个全角空格
                Text(verbatim: "\u{3000}\u{3000}" + entry.text.trimmed)
                    .font(Typo.serif(Typo.Book.diary))
                    .lineSpacing(Typo.Book.diarySpacing)
                    .tracking(Typo.tracking)
                    .foregroundStyle(Palette.ink)
                    // 一页放得下的行数；更长的日记末尾省略（日记不会太长，见 Companion 写日记的要求）
                    .lineLimit(Self.maxLines)
                    .reveal(1)
                HStack(spacing: Space.item) {
                    Capsule().frame(width: Space.page, height: 0.5)
                    Text(verbatim: author)
                }
                .font(.system(size: Typo.caption))
                .tracking(Typo.labelTracking)
                .foregroundStyle(Palette.inkSoft)
                .reveal(2)
            }
            .padding(.top, Space.bookBottom)
        }
    }
}
