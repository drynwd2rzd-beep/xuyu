import SwiftUI
import SwiftData

/// Today：一本画册，一屏一个瞬间，上下翻页（设计稿 home.html）。
/// 封面是照片和 TA 今天的那句话，往后是 TA 此刻（心情光晕）、今天的待办、TA 的日记、一起听、TA 的动态；
/// 没有内容的那几页（还没有日记、没一起听过、没有带照片的动态）不出现。
/// 点封面上的日期打开月历，去看以前的某一天（那天的日记、做完的事、你发的动态）或以后的某一天（那天的安排）
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(RelayClient.self) private var relay
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @Query(sort: \DiaryEntry.day, order: .reverse) private var entries: [DiaryEntry]
    @Query(sort: \Moment.createdAt, order: .reverse) private var moments: [Moment]
    @Query private var photos: [AlbumPhoto]
    @AppStorage(Prefs.whisperAuthor) private var author = ""
    @AppStorage(Prefs.diaryWriter) private var writerID = ""
    /// 在月历里点的那一天
    @State private var day = DemoMode.isOn && DemoMode.screen == "past" ? Date.now.startOfDay.adding(days: -1) : Date.now.startOfDay
    @State private var calendarOpen = DemoMode.isOn && DemoMode.screen == "calendar"
    @State private var dayOpen = DemoMode.isOn && DemoMode.screen == "past"

    /// 画册里的一页
    private enum Page {
        case cover, now(Persona), todo, diary(DiaryEntry), listen(ListenTogether.Song), post(Moment, AlbumPhoto)
    }

    var body: some View {
        let pages = book
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    view(page, number: index + 1, total: pages.count)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .background(Palette.paper)
        .sheet(isPresented: $calendarOpen, onDismiss: {
            // 选了别的日子：月历收起后再打开那一天（NAV-3）
            if !Calendar.current.isDateInToday(day) { dayOpen = true }
        }) {
            DayCalendarSheet(day: $day)
                .presentationDetents([.height(440)])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        .sheet(isPresented: $dayOpen, onDismiss: { day = Date.now.startOfDay }) {
            DaySheet(day: day)
                .presentationDetents([.large])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        // 看到今天的日记还没写、又已经过了 8 点：马上去写（不用等下次打开 App）
        .task(id: "\(relay.isConnected)") {
            guard Clock.hour() >= Limits.Hours.diary else { return }
            await Companion.writeDiaries(context: context, relay: relay)
        }
    }

    // MARK: - 有哪几页

    private var book: [Page] {
        var pages: [Page] = [.cover]
        if let who = nowPersona { pages.append(.now(who)) }
        pages.append(.todo)
        if let entry = entries.first(where: { $0.author == .ai && !$0.text.trimmed.isEmpty && $0.text != "……" }) {
            pages.append(.diary(entry))
        }
        let music = ListenTogether.shared
        if let song = music.now ?? music.history.first { pages.append(.listen(song)) }
        if let post = latestPost { pages.append(.post(post.0, post.1)) }
        return pages
    }

    /// 「此刻」那一页写谁：今天那句话是谁写的就是谁，不然是写日记的那位
    private var nowPersona: Persona? {
        personas.first { $0.name == author } ?? personas.first { $0.id.uuidString == writerID } ?? personas.first
    }

    /// TA 们最近一条带照片、已经到点出现的动态
    private var latestPost: (Moment, AlbumPhoto)? {
        for m in moments where m.personaID != nil && m.createdAt <= .now {
            if let id = m.photoIDs.first, let photo = photos.first(where: { $0.id == id }) { return (m, photo) }
        }
        return nil
    }

    @ViewBuilder
    private func view(_ page: Page, number: Int, total: Int) -> some View {
        switch page {
        case .cover:
            CoverPage(total: total) { calendarOpen = true }
        case .now(let persona):
            NowPage(persona: persona, number: number, total: total)
        case .todo:
            TodoPage(number: number, total: total)
        case .diary(let entry):
            let name = entry.personaID.map { id in personas.first { $0.id == id }?.name ?? String(localized: "已删除的角色") }
            DiaryPage(entry: entry, author: name ?? personas.first?.name ?? "", number: number, total: total)
        case .listen(let song):
            ListenPage(song: song, number: number, total: total)
        case .post(let moment, let photo):
            PostPage(moment: moment, photo: photo, names: Dictionary(personas.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }),
                     number: number, total: total)
        }
    }
}

/// 在月历里点开的那一天：以前的日子看那天的日记、做完的事、你发的动态；以后的日子看那天的安排
private struct DaySheet: View {
    let day: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: title)
                        .font(.system(size: Typo.heading, weight: .light))
                        .tracking(Typo.labelTracking)
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Button { dismiss() } label: {
                        Text("Today")
                            .font(.system(size: Typo.label))
                            .tracking(Typo.tracking)
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, Space.card)
                            .frame(height: Space.field)
                            .background(Palette.card, in: Capsule())
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .accessibilityLabel("回到今天")
                }
                .padding(.horizontal, Space.tight)
                if day < Date.now.startOfDay {
                    PastDayCards(day: day)
                } else {
                    TodoCard(day: day)
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.group)
            .padding(.bottom, Space.bottom)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var title: String {
        let cal = Calendar.current
        if cal.isDateInYesterday(day) { return "Yesterday" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        return Fmt.enMonthDay.string(from: day)
    }
}
