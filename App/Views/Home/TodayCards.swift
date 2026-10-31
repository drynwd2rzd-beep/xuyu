import SwiftUI
import SwiftData

/// Today 页里的待办：今天要做的（含没定日子的、过期的），末尾一行直接写新待办；做完的收成一行「N done」，点开再看。
/// 以后的某一天也用它，标题换成 Plans，新写的就记在那一天
struct TodoCard: View {
    let day: Date
    /// 点「之后」那一行：跳到那一天
    var onJump: (Date) -> Void = { _ in }
    @Environment(\.modelContext) private var context
    @Query(sort: \TodoItem.createdAt) private var items: [TodoItem]
    @State private var newTitle = ""
    @State private var editing: TodoItem?
    @State private var doneOpen = false
    @FocusState private var adding: Bool

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var end: Date { day.adding(days: 1) }

    private var pending: [TodoItem] {
        items.filter { item in
            guard !item.isDone else { return false }
            if isToday { return (item.dueDate ?? .distantPast) < end }
            guard let d = item.dueDate else { return false }
            return d >= day && d < end
        }
        .sorted(by: TodoItem.order)
    }

    private var finished: [TodoItem] {
        items.filter { item in
            guard item.isDone else { return false }
            if isToday { return (item.completedAt ?? .distantPast) >= day }
            guard let d = item.dueDate else { return false }
            return d >= day && d < end
        }
        .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    private var upcoming: [TodoItem] {
        items.filter { !$0.isDone && ($0.dueDate ?? .distantPast) >= end }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    var body: some View {
        let open = pending, done = finished
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(isToday ? "To do" : "Plans").font(Typo.serif(22)).foregroundStyle(Palette.ink)
                Spacer()
                if !open.isEmpty || !done.isEmpty {
                    Text("\(done.count) / \(open.count + done.count)")
                        .font(Typo.serif(14))
                        .foregroundStyle(Palette.inkSoft)
                        .contentTransition(.numericText())
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 4)

            ForEach(open) { item in
                row(item)
                Hairline(inset: 36)
            }

            addRow

            if !done.isEmpty {
                Hairline(inset: 36)
                Button { withAnimation(Motion.spring) { doneOpen.toggle() } } label: {
                    HStack(spacing: Space.tight) {
                        ZStack {
                            Circle().fill(Palette.ink)
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.inkInverse)
                        }
                        .frame(width: 22, height: 22)
                        .frame(width: 28)
                        Text("\(done.count) done").font(Typo.serif(15).italic()).foregroundStyle(Palette.inkSoft)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.inkSoft)
                            .rotationEffect(.degrees(doneOpen ? 180 : 0))
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(doneOpen ? Text("已展开") : Text("已收起"))
                if doneOpen {
                    ForEach(done) { item in
                        Hairline(inset: 36)
                        row(item)
                    }
                }
            }

            if isToday, let next = upcoming.first, let nextDay = next.dueDate {
                Hairline(inset: 36)
                Button { onJump(nextDay.startOfDay) } label: {
                    HStack(spacing: Space.tight) {
                        Text("Later").font(Typo.serif(14).italic()).foregroundStyle(Palette.inkSoft).frame(width: 44, alignment: .leading)
                        Text(upcoming.prefix(2).map { "\($0.title) · \(Fmt.weekday.string(from: $0.dueDate ?? .now))" }.joined(separator: "  ·  "))
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.inkSoft)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Chevron()
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, 6)
        .card()
        .animation(Motion.spring, value: open.map(\.id) + done.map(\.id))
        .sheet(item: $editing) { item in
            TodoEditor(item: item)
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
    }

    private func row(_ item: TodoItem) -> some View {
        TodoRow(item: item, onToggle: { toggle(item) }, onOpen: { editing = item })
            .contextMenu {
                if !item.isDone {
                    Button { postpone(item) } label: { Label("推到明天", systemImage: "arrow.turn.down.right") }
                }
                Button(role: .destructive) { delete(item) } label: { Label("删除", systemImage: "trash") }
            }
            .transition(.opacity)
    }

    /// 写新待办：就在清单末尾，像在本子上接着写一行
    private var addRow: some View {
        HStack(spacing: Space.tight) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Palette.inkSoft)
                .frame(width: 28)
            TextField(isToday ? "新待办" : "这一天要做的事", text: $newTitle)
                .font(.system(size: Typo.body))
                .foregroundStyle(Palette.ink)
                .focused($adding)
                .submitLabel(.done)
                .onSubmit(add)
        }
        .frame(minHeight: 50)
    }

    private func add() {
        let title = newTitle.trimmed
        guard !title.isEmpty else { return }
        let item = TodoItem(title: title, dueDate: isToday ? nil : day)
        withAnimation(Motion.spring) { context.insert(item) }
        context.persist()
        newTitle = ""
    }

    private func toggle(_ item: TodoItem) {
        withAnimation(Motion.spring) {
            item.isDone.toggle()
            item.completedAt = item.isDone ? .now : nil
        }
        context.persist()
        Reminders.sync(item)
    }

    private func postpone(_ item: TodoItem) {
        let base = (item.dueDate ?? .now).startOfDay.adding(days: 1)
        if item.hasTime, let due = item.dueDate {
            item.dueDate = due.adding(days: 1)
        } else {
            item.dueDate = max(base, Date.now.startOfDay.adding(days: 1))
        }
        context.persist()
        Reminders.sync(item)
    }

    private func delete(_ item: TodoItem) {
        Reminders.cancel(item)
        withAnimation(Motion.spring) { context.delete(item) }
        context.persist()
    }
}

/// TA 的日记：写好了才出现（正在写时显示一行「正在写」）。长按可以换由谁来写
struct TaDiaryCard: View {
    let day: Date
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @Query(sort: \DiaryEntry.createdAt) private var entries: [DiaryEntry]
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @AppStorage(Prefs.diaryWriter) private var writerID = ""
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var shortHeight: CGFloat = 0

    /// 你选的那位写的；以前的日子 TA 没写，就显示当天别人写的
    private var entry: DiaryEntry? {
        let ai = entries.filter { $0.day == day.startOfDay && $0.author == .ai && $0.text != "……" }
        if let mine = ai.first(where: { $0.personaID == writer?.id }) { return mine }
        return Calendar.current.isDateInToday(day) ? nil : ai.first
    }
    private var writer: Persona? { personas.first { $0.id.uuidString == writerID } ?? personas.first }
    /// 写这篇的人。记着作者、但作者已经删了：不署别人的名字，也不显示 Reply（以前会退回成现在写日记的人）
    private var author: Persona? {
        guard let id = entry?.personaID else { return writer }
        return personas.first { $0.id == id }
    }
    private var writing: Bool { DiaryState.shared.writing.contains(day.startOfDay) }

    var body: some View {
        if let entry {
            card(entry)
        } else if writing {
            HStack(spacing: Space.tight) {
                AvatarView(persona: writer, size: 22)
                Text("\(writer?.name ?? "TA") 正在写今天的日记").font(.system(size: Typo.secondary)).foregroundStyle(Palette.inkSoft)
                TypingDots().scaleEffect(0.7, anchor: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.card)
            .frame(minHeight: 52)
            .card()
            .transition(.opacity)
        }
    }

    private func card(_ entry: DiaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: Space.tight) {
                Text("\(author?.name ?? "TA")’s diary").font(Typo.serif(22)).foregroundStyle(Palette.ink).lineLimit(1)
                if !entry.mood.isEmpty { MoodTag(text: entry.mood) }
                Spacer(minLength: 0)
                Text(Fmt.hm.string(from: entry.createdAt)).font(Typo.serif(13).italic()).foregroundStyle(Palette.inkSoft)
            }
            foldingText(entry.text)
            if let author {
                Button {
                    router.tab = .chats
                    router.open(.chat(context.chat(for: author).id))
                } label: {
                    Text("Reply →").font(Typo.serif(16).italic()).foregroundStyle(Palette.ink)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("回 \(author.name) 的日记")
            }
        }
        .padding(.horizontal, Space.card + 4)
        .padding(.top, 18)
        .padding(.bottom, 4)
        .card()
        .contextMenu {
            if personas.count > 1 {
                Section("由谁来写日记") {
                    ForEach(personas) { p in
                        Button { writerID = p.id.uuidString } label: {
                            if p.id == writer?.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                        }
                    }
                }
            }
        }
        .transition(.opacity)
        .onChange(of: day) { expanded = false }
    }

    /// 平时显示四行，点一下平滑地长出全文，再点一下缩回去。收起时最后一行轻轻淡出，提示还有下文
    private func foldingText(_ text: String) -> some View {
        let canFold = fullHeight > shortHeight + 1
        let folded = canFold && !expanded
        return Text(text)
            .font(Typo.serif(15.5))
            .lineSpacing(8)
            .foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            .background(alignment: .top) {
                Text(text)
                    .font(Typo.serif(15.5))
                    .lineSpacing(8)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shortHeight = $0 }
            }
            .frame(height: fullHeight == 0 ? nil : (folded ? shortHeight : fullHeight), alignment: .top)
            .clipped()
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(folded ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard canFold else { return }
                withAnimation(Motion.spring) { expanded.toggle() }
            }
            .sensoryFeedback(.selection, trigger: expanded)
    }
}

/// 以前的某一天：TA 那天的日记、那天做完的事、你那天发的动态
struct PastDayCards: View {
    let day: Date
    @Environment(Router.self) private var router
    @Query(sort: \TodoItem.createdAt) private var items: [TodoItem]
    @Query(sort: \Moment.createdAt) private var moments: [Moment]
    @Query private var photos: [AlbumPhoto]
    @Query(sort: \DiaryEntry.createdAt) private var entries: [DiaryEntry]

    private var end: Date { day.adding(days: 1) }
    private var done: [TodoItem] {
        items.filter { $0.isDone && ($0.completedAt ?? .distantPast) >= day && ($0.completedAt ?? .distantPast) < end }
            .sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
    }
    /// 那天该做、到现在还没做的（在今天的清单里显示为逾期）
    private var left: Int {
        items.filter { !$0.isDone && ($0.dueDate ?? .distantFuture) >= day && ($0.dueDate ?? .distantFuture) < end }.count
    }
    private var mine: Moment? { moments.last { $0.personaID == nil && $0.createdAt >= day && $0.createdAt < end } }
    private var hasDiary: Bool { entries.contains { $0.day == day && $0.author == .ai && $0.text != "……" } }

    var body: some View {
        VStack(spacing: Space.section) {
            TaDiaryCard(day: day)
            if !done.isEmpty || left > 0 { doneCard }
            if let mine { momentCard(mine) }
            if !hasDiary && done.isEmpty && left == 0 && mine == nil {
                Text("这一天很安静。")
                    .font(Typo.serif(16).italic())
                    .foregroundStyle(Palette.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, Space.item)
            }
        }
    }

    private var doneCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Done").font(Typo.serif(22)).foregroundStyle(Palette.ink).padding(.top, 4).padding(.bottom, 4)
            ForEach(done) { item in
                HStack(spacing: Space.tight) {
                    ZStack {
                        Circle().fill(Palette.ink)
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.inkInverse)
                    }
                    .frame(width: 22, height: 22)
                    .frame(width: 28)
                    Text(item.title).font(.system(size: Typo.body)).foregroundStyle(Palette.ink).lineLimit(2)
                    Spacer(minLength: Space.tight)
                    if let at = item.completedAt {
                        Text(Fmt.hm.string(from: at)).font(Typo.serif(13).italic()).foregroundStyle(Palette.inkSoft)
                    }
                }
                .frame(minHeight: 50)
                if item.id != done.last?.id || left > 0 { Hairline(inset: 36) }
            }
            if left > 0 {
                HStack(spacing: Space.tight) {
                    Circle()
                        .strokeBorder(Palette.faint, style: StrokeStyle(lineWidth: 1.4, dash: [3, 2.5]))
                        .frame(width: 22, height: 22)
                        .frame(width: 28)
                    Text("\(left) 件没做完").font(.system(size: 14.5)).foregroundStyle(Palette.inkSoft)
                    Spacer()
                }
                .frame(minHeight: 48)
            }
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, 6)
        .card()
    }

    private func momentCard(_ m: Moment) -> some View {
        Button {
            router.path = NavigationPath()
            router.tab = .moments
        } label: {
            HStack(spacing: Space.item) {
                if let id = m.photoIDs.first, let p = photos.first(where: { $0.id == id }),
                   let image = cachedImage(p.data, key: p.id.uuidString, maxPixel: 300) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("your moment").font(Typo.serif(13.5).italic()).foregroundStyle(Palette.inkSoft)
                    Text(m.text.isEmpty ? String(localized: "（图片）") : m.text)
                        .font(.system(size: 14.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Chevron()
            }
            .padding(.horizontal, Space.card)
            .padding(.vertical, Space.item)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .card(radius: 22)
    }
}

/// 点日期弹出的月历：点哪天就去哪天（今天回到 Today）。小圆点：那天有 TA 的日记或安排
struct DayCalendarSheet: View {
    @Binding var day: Date
    @Environment(\.dismiss) private var dismiss
    @Query private var items: [TodoItem]
    @Query private var entries: [DiaryEntry]

    private var marked: Set<Date> {
        Set(items.filter { !$0.isDone }.compactMap { $0.dueDate?.startOfDay })
            .union(entries.filter { $0.author == .ai }.map(\.day))
    }

    var body: some View {
        let pick = Binding(get: { day }, set: { new in
            withAnimation(Motion.spring) { day = new }
            dismiss()
        })
        FoldingCalendar(selected: pick, marked: marked, open: true)
            .padding(.horizontal, Space.tight)
            .padding(.vertical, Space.item)
            .card()
            .padding(.horizontal, Space.item)
            .padding(.top, 28)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}
