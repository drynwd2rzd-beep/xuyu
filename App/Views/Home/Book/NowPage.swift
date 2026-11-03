import SwiftUI
import SwiftData

/// 画册「TA 此刻」：一团跟着 TA 心情变颜色的光，下面是心情那个词和 TA 这会儿在做的事。
/// 心情来自 TA 最近一篇日记（DiaryEntry.mood），在做的事来自 TA 今天的安排（World.current）
struct NowPage: View {
    let persona: Persona
    let number: Int
    let total: Int
    @Query(sort: \DiaryEntry.day, order: .reverse) private var entries: [DiaryEntry]

    private var mood: String {
        entries.first { $0.author == .ai && $0.personaID == persona.id && !$0.mood.isEmpty }?.mood ?? ""
    }

    var body: some View {
        let glow = MoodTint.glow(for: mood)
        TimelineView(.everyMinute) { ctx in
            PhotobookPage(folio: String(localized: "\(persona.name)　此刻"), number: number, total: total) {
                LinearGradient(stops: [
                    .init(color: glow.t1, location: 0),
                    .init(color: glow.t2, location: 0.58),
                    .init(color: Palette.paper, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .animation(Motion.glide, value: glow)
                GeometryReader { geo in
                    MoodGlow(glow: glow, size: geo.size.width * 0.82)
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.39)
                }
            } content: {
                VStack(alignment: .leading, spacing: Space.item) {
                    Text("心情")
                        .font(.system(size: Typo.caption))
                        .tracking(Typo.labelTracking)
                        .foregroundStyle(Palette.inkSoft)
                        .reveal()
                    Text(verbatim: mood.isEmpty ? String(localized: "平静") : mood)
                        .font(.system(size: Typo.Book.mood, weight: .ultraLight))
                        .tracking(Typo.labelTracking)
                        .foregroundStyle(Palette.ink)
                        .contentTransition(.opacity)
                        .reveal()
                    if let doing = doing(at: ctx.date) {
                        Text(verbatim: doing)
                            .font(Typo.serif(Typo.Book.prose))
                            .lineSpacing(Typo.Book.proseSpacing)
                            .foregroundStyle(Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .reveal(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// TA 这会儿在做的事；睡着了就说在睡觉
    private func doing(at date: Date) -> String? {
        if World.status(of: persona.id, at: date) == .asleep { return String(localized: "在睡觉。") }
        return World.current(of: persona.id, at: date)?.what
    }
}
