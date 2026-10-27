import SwiftUI
import SwiftData

struct TodoView: View {
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @Query(sort: \TodoItem.createdAt) private var items: [TodoItem]
    @State private var selectedDay = Date.now.startOfDay
    @State private var monthOpen = false
    @State private var newTitle = ""
    @State private var editing: TodoItem?
    @FocusState private var addFocused: Bool

    private var isToday: Bool { Calendar.current.isDateInToday(selectedDay) }

    private var dayItems: [TodoItem] {
        let start = selectedDay, end = start.adding(days: 1)
        return items.filter { item in
            if isToday {
                if item.isDone { return (item.completedAt ?? .distantPast) >= start }
                return (item.dueDate ?? .distantPast) < end
            }
            guard let d = item.dueDate else { return false }
            return d >= start && d < end
        }
        .sorted(by: TodoItem.order)
    }

    private var upcoming: [TodoItem] {
        let end = Date.now.startOfDay.adding(days: 1)
        return items.filter { !$0.isDone && ($0.dueDate ?? .distantPast) >= end }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private var markedDays: Set<Date> {
        Set(items.filter { !$0.isDone }.compactMap { $0.dueDate?.startOfDay })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                PageTitle(title: "To Do") {
                    CircleIconButton(systemName: "slider.horizontal.3", label: "设置") { router.open(.settings) }
                        .padding(.bottom, Space.tight)
                }
                weekCard
                todoCard
                DiaryCard(day: selectedDay)
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.top)
            .padding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $editing) { item in
            TodoEditor(item: item)
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
    }

    // MARK: - 日期

    private var weekCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(Motion.spring) { monthOpen.toggle() } } label: {
                HStack(spacing: 5) {
                    Text(Fmt.enMonth.string(from: selectedDay)).font(Typo.serif(15)).foregroundStyle(Palette.ink)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.inkSoft)
                        .rotationEffect(.degrees(monthOpen ? 180 : 0))
                }
                .frame(height: 30)
                .padding(.leading, Space.tight)
            }
            .buttonStyle(.plain)
            FoldingCalendar(selected: $selectedDay, marked: markedDays, open: monthOpen)
        }
        .padding(Space.tight)
        .card()
        .sensoryFeedback(.selection, trigger: selectedDay)
    }

    // MARK: - 当天待办

    private var todoCard: some View {
        let list = dayItems
        let open = list.filter { !$0.isDone }.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(isToday ? "今天" : Fmt.weekdayMD.string(from: selectedDay))
                    .font(Typo.serif(20, .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                if !list.isEmpty {
                    Text(open > 0 ? "\(open) 件待办" : "全部完成").font(.system(size: 13)).foregroundStyle(Palette.inkSoft)
                }
            }
            .padding(.bottom, 2)

            ForEach(list) { item in
                TodoRow(item: item, onToggle: { toggle(item) }, onOpen: { editing = item })
                    .contextMenu {
                        Button { postpone(item) } label: { Label("推到明天", systemImage: "arrow.turn.down.right") }
                        Button(role: .destructive) { delete(item) } label: { Label("删除", systemImage: "trash") }
                    }
                if item.id != list.last?.id { Hairline(inset: 36) }
            }
            if list.isEmpty {
                Text("这一天还没有安排").font(.system(size: 14)).foregroundStyle(Palette.inkSoft).padding(.vertical, 14)
            }

            HStack(spacing: Space.tight) {
                TextField(isToday ? "记一条今天要做的事…" : "给这一天加一件事…", text: $newTitle)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.ink)
                    .focused($addFocused)
                    .submitLabel(.done)
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.inkInverse)
                        .frame(width: 34, height: 34)
                        .background(newTitle.trimmed.isEmpty ? Palette.faint : Palette.ink, in: Circle())
                }
                .disabled(newTitle.trimmed.isEmpty)
                .accessibilityLabel("添加")
            }
            .padding(.leading, 15)
            .padding(.trailing, 4)
            .frame(height: Space.control)
            .background(Palette.paper, in: Capsule())
            .padding(.top, 6)

            if isToday, !upcoming.isEmpty {
                Button {
                    if let first = upcoming.first?.dueDate { withAnimation(Motion.spring) { selectedDay = first.startOfDay } }
                } label: {
                    HStack(spacing: Space.tight) {
                        Text("之后").font(Typo.serif(13)).foregroundStyle(Palette.ink2)
                        Text(upcoming.prefix(2).map { "\($0.title) · \(Fmt.weekday.string(from: $0.dueDate ?? .now))" }.joined(separator: "  ·  "))
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.inkSoft)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Chevron()
                    }
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, Space.item)
        .card()
        .animation(Motion.spring, value: list.map(\.id))
    }

    // MARK: - 动作

    private func add() {
        let title = newTitle.trimmed
        guard !title.isEmpty else { return }
        let item = TodoItem(title: title, dueDate: isToday ? nil : selectedDay)
        withAnimation(Motion.spring) { context.insert(item) }
        try? context.save()
        newTitle = ""
    }

    private func toggle(_ item: TodoItem) {
        withAnimation(Motion.spring) {
            item.isDone.toggle()
            item.completedAt = item.isDone ? .now : nil
        }
        try? context.save()
        Reminders.sync(item)
    }

    private func postpone(_ item: TodoItem) {
        let base = (item.dueDate ?? .now).startOfDay.adding(days: 1)
        if item.hasTime, let due = item.dueDate {
            item.dueDate = due.adding(days: 1)
        } else {
            item.dueDate = max(base, Date.now.startOfDay.adding(days: 1))
        }
        try? context.save()
        Reminders.sync(item)
    }

    private func delete(_ item: TodoItem) {
        Reminders.cancel(item)
        withAnimation(Motion.spring) { context.delete(item) }
        try? context.save()
    }
}

struct TodoRow: View {
    let item: TodoItem
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: Space.tight) {
            Button(action: onToggle) {
                ZStack {
                    Circle().strokeBorder(item.isDone ? Palette.ink : Palette.faint, lineWidth: 1.5)
                    if item.isDone {
                        Circle().fill(Palette.ink)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Palette.inkInverse)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 22, height: 22)
                .frame(width: 28, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: item.isDone) { _, new in new }
            .accessibilityLabel(item.isDone ? "标记为未完成" : "标记为完成")

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 16))
                    .foregroundStyle(item.isDone ? Palette.inkSoft : Palette.ink)
                    .strikethrough(item.isDone, color: Palette.inkSoft)
                    .lineLimit(2)
                if let sub = subtitle {
                    Text(sub).font(.system(size: 12)).foregroundStyle(overdue ? Palette.danger : Palette.inkSoft)
                }
            }
            Spacer(minLength: Space.tight)
            if item.remind && !item.isDone {
                Image(systemName: "bell").font(.system(size: 13)).foregroundStyle(Palette.inkSoft)
            }
        }
        .frame(minHeight: 50)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private var overdue: Bool {
        guard !item.isDone, let due = item.dueDate else { return false }
        return due < Date.now.startOfDay
    }

    private var subtitle: String? {
        if item.isDone, let done = item.completedAt { return "已完成 · " + Fmt.hm.string(from: done) }
        if overdue, let due = item.dueDate { return "已逾期 · " + Fmt.md.string(from: due) }
        if let due = item.dueDate, item.hasTime {
            return Fmt.hm.string(from: due) + (item.remind ? (item.remindLead > 0 ? " · 提前 \(item.remindLead) 分钟提醒" : " · 准时提醒") : "")
        }
        if item.dueDate != nil { return nil }
        let cal = Calendar.current
        return (cal.isDateInToday(item.createdAt) ? Fmt.hm.string(from: item.createdAt) : Fmt.md.string(from: item.createdAt)) + " 添加"
    }
}

/// 可以折叠的日历：收起时只显示选中日期所在的那一周；展开时那一周原地不动，
/// 上下几周平滑地展开出来（和 iPhone 自带日历一样），收起时再折回去
struct FoldingCalendar: View {
    @Binding var selected: Date
    let marked: Set<Date>
    let open: Bool
    @State private var month = Date.now.startOfDay
    @Namespace private var dayNS
    private let rowHeight: CGFloat = 46

    private var cal: Calendar { Calendar.current }

    /// 这个月要显示的几周（每周 7 天，前后用相邻月份的日子补齐）
    private var weeks: [[Date]] {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        let start = cal.dateInterval(of: .weekOfYear, for: first)?.start ?? first
        let count = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let last = first.adding(days: count - 1)
        var rows: [[Date]] = []
        var day = start
        while day <= last {
            rows.append((0..<7).map { day.adding(days: $0) })
            day = day.adding(days: 7)
        }
        return rows
    }

    private var selectedRow: Int {
        weeks.firstIndex { row in row.contains { cal.isDate($0, inSameDayAs: selected) } } ?? 0
    }

    var body: some View {
        let rows = weeks
        let keep = selectedRow
        VStack(spacing: 4) {
            // 月份切换：只在展开时出现
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 40, height: 30) }
                Spacer()
                Text(Fmt.enMonth.string(from: month) + " " + String(cal.component(.year, from: month)))
                    .font(Typo.serif(14))
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 40, height: 30) }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .frame(height: open ? 30 : 0)
            .opacity(open ? 1 : 0)
            .clipped()

            // 星期一直都在
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(cal.veryShortStandaloneWeekdaySymbols[(cal.firstWeekday - 1 + i) % 7])
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.inkSoft)
                        .frame(maxWidth: .infinity)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    let visible = open || index == keep
                    HStack(spacing: 0) {
                        ForEach(row, id: \.self) { day in
                            DayCell(day: day, selected: cal.isDate(day, inSameDayAs: selected),
                                    marked: marked.contains(day.startOfDay),
                                    outside: !cal.isDate(day, equalTo: month, toGranularity: .month), ns: dayNS) {
                                withAnimation(Motion.spring) { selected = day.startOfDay }
                            }
                        }
                    }
                    // 收起时其他几周高度变成 0、淡出并稍微往选中那周收拢
                    .frame(height: visible ? rowHeight : 0, alignment: index < keep ? .bottom : .top)
                    .opacity(visible ? 1 : 0)
                    .scaleEffect(visible ? 1 : 0.92, anchor: index < keep ? .bottom : .top)
                    .clipped()
                }
            }
        }
        .onAppear { month = selected }
        // 收起前先回到选中日期所在的月份，这样折回去的就是选中的那一周
        .onChange(of: open) { _, isOpen in
            if !isOpen, !cal.isDate(month, equalTo: selected, toGranularity: .month) {
                withAnimation(Motion.spring) { month = selected }
            }
        }
        .onChange(of: selected) { _, day in
            if !cal.isDate(month, equalTo: day, toGranularity: .month) {
                withAnimation(Motion.spring) { month = day }
            }
        }
    }

    private func shift(_ delta: Int) {
        withAnimation(Motion.spring) {
            month = cal.date(byAdding: .month, value: delta, to: month) ?? month
        }
    }
}

private struct DayCell: View {
    let day: Date
    let selected: Bool
    let marked: Bool
    var outside = false
    /// 选中的黑色圆点在日子之间平滑滑动
    var ns: Namespace.ID? = nil
    let onTap: () -> Void

    var body: some View {
        let today = Calendar.current.isDateInToday(day)
        Button(action: onTap) {
            VStack(spacing: 3) {
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.inkInverse : (outside ? Palette.faint : Palette.ink2))
                    .frame(width: 34, height: 34)
                    .background {
                        if selected {
                            if let ns {
                                Circle().fill(Palette.ink).matchedGeometryEffect(id: "selectedDay", in: ns)
                            } else {
                                Circle().fill(Palette.ink)
                            }
                        } else if today {
                            Circle().strokeBorder(Palette.ink, lineWidth: 1)
                        }
                    }
                Circle().fill(marked && !selected ? Palette.ink : Color.clear).frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
