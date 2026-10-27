import SwiftUI
import SwiftData

enum HomeWidget: String, CaseIterable, Identifiable {
    case whisper, days, todo, diary, countdown, mood, memory

    var id: String { rawValue }
    var wide: Bool { self == .whisper || self == .diary }

    var label: String {
        switch self {
        case .whisper: "今日一句"
        case .days: "在一起"
        case .todo: "今日待办"
        case .diary: "日记"
        case .countdown: "倒数日"
        case .mood: "心情"
        case .memory: "回忆"
        }
    }

    var symbol: String {
        switch self {
        case .whisper: "sparkle"
        case .days: "heart"
        case .todo: "checklist"
        case .diary: "book.closed"
        case .countdown: "hourglass"
        case .mood: "chart.bar"
        case .memory: "photo"
        }
    }

    static let defaults: [HomeWidget] = [.whisper, .days, .todo, .diary]
}

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @AppStorage(Prefs.homeWidgets) private var widgetsRaw = HomeWidget.defaults.map(\.rawValue).joined(separator: ",")
    @AppStorage(Prefs.nickname) private var nickname = ""
    @State private var showGallery = false

    private var widgets: [HomeWidget] {
        widgetsRaw.split(separator: ",").compactMap { HomeWidget(rawValue: String($0)) }
    }

    private var editing: Bool { router.homeEditing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                TimelineView(.everyMinute) { ctx in
                    PageTitle(caption: Fmt.enLong.string(from: ctx.date), title: greeting(ctx.date)) {
                        if editing {
                            Button("完成") { setEditing(false) }
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Palette.inkInverse)
                                .padding(.horizontal, Space.card)
                                .frame(height: 36)
                                .background(Palette.ink, in: Capsule())
                                .padding(.bottom, Space.tight)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .padding(.bottom, Space.tight)

                VStack(spacing: Space.item) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        if row.count == 1 && row[0].wide {
                            cell(row[0])
                        } else {
                            HStack(spacing: Space.item) {
                                ForEach(row) { cell($0) }
                                if row.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.top)
            .padding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            if editing {
                Button { showGallery = true } label: {
                    Label("添加小组件", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 22)
                        .frame(height: 50)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.09), radius: 18, y: 8)
                }
                .buttonStyle(ScaleButtonStyle())
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showGallery) {
            WidgetGallery(added: Set(widgets)) { add($0) }
                .presentationDetents([.height(360)])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        .onChange(of: router.tab) { _, tab in if tab != .home { setEditing(false) } }
    }

    private func greeting(_ date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let base = switch hour {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        case 18..<23: "Good evening"
        default: "Good night"
        }
        let name = nickname.trimmed
        return name.isEmpty ? base : "\(base),\n\(name)"
    }

    /// 宽组件独占一行，小组件两两并排
    private var rows: [[HomeWidget]] {
        var result: [[HomeWidget]] = []
        var pending: [HomeWidget] = []
        for w in widgets {
            if w.wide {
                if !pending.isEmpty { result.append(pending); pending = [] }
                result.append([w])
            } else {
                pending.append(w)
                if pending.count == 2 { result.append(pending); pending = [] }
            }
        }
        if !pending.isEmpty { result.append(pending) }
        return result
    }

    private func cell(_ widget: HomeWidget) -> some View {
        WidgetCell(widget: widget, editing: editing, index: widgets.firstIndex(of: widget) ?? 0) {
            remove(widget)
        } onOpen: {
            open(widget)
        }
        .modifier(Reorderable(editing: editing, widget: widget, onEdit: { setEditing(true) }, onMove: move))
    }

    /// 拖动排序：把 from 放到 to 的位置
    private func move(_ from: HomeWidget, to: HomeWidget) {
        var list = widgets
        guard let source = list.firstIndex(of: from), let target = list.firstIndex(of: to), source != target else { return }
        list.remove(at: source)
        list.insert(from, at: target)
        withAnimation(Motion.spring) {
            widgetsRaw = list.map(\.rawValue).joined(separator: ",")
        }
    }

    private func setEditing(_ on: Bool) {
        withAnimation(Motion.spring) { router.homeEditing = on }
    }

    private func remove(_ widget: HomeWidget) {
        withAnimation(Motion.spring) {
            widgetsRaw = widgets.filter { $0 != widget }.map(\.rawValue).joined(separator: ",")
        }
    }

    private func add(_ widget: HomeWidget) {
        withAnimation(Motion.spring) {
            widgetsRaw = (widgets + [widget]).map(\.rawValue).joined(separator: ",")
        }
        showGallery = false
    }

    private func open(_ widget: HomeWidget) {
        switch widget {
        case .whisper, .days, .memory:
            let personas = context.allPersonas()
            if let first = personas.first {
                router.tab = .chats
                router.open(.chat(context.chat(for: first).id))
            }
        case .todo, .diary, .countdown, .mood:
            withAnimation(Motion.spring) { router.tab = .todo }
        }
    }
}

/// 平时长按进入编辑；编辑时按住拖动可以换位置
private struct Reorderable: ViewModifier {
    let editing: Bool
    let widget: HomeWidget
    let onEdit: () -> Void
    let onMove: (HomeWidget, HomeWidget) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        if editing {
            content
                .draggable(widget.rawValue)
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, let from = HomeWidget(rawValue: raw), from != widget else { return false }
                    onMove(from, widget)
                    return true
                } isTargeted: { on in
                    withAnimation(Motion.snappy) { targeted = on }
                }
                .scaleEffect(targeted ? 0.96 : 1)
                .opacity(targeted ? 0.7 : 1)
        } else {
            content.onLongPressGesture(minimumDuration: 0.45, perform: onEdit)
        }
    }
}

private struct WidgetCell: View {
    let widget: HomeWidget
    let editing: Bool
    let index: Int
    let onRemove: () -> Void
    let onOpen: () -> Void
    @State private var wiggle = false

    var body: some View {
        content
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .onTapGesture { if !editing { onOpen() } }
            .rotationEffect(.degrees(editing ? (wiggle ? 0.8 : -0.8) : 0))
            .animation(editing ? .easeInOut(duration: 0.16).repeatForever(autoreverses: true).delay(Double(index) * 0.05) : .default,
                       value: wiggle)
            .overlay(alignment: .topLeading) {
                if editing {
                    Button(action: onRemove) {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Palette.faint, in: Circle())
                            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    }
                    .offset(x: -7, y: -7)
                    .accessibilityLabel("移除\(widget.label)")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .onChange(of: editing, initial: true) { _, on in wiggle = on }
            .sensoryFeedback(.impact(weight: .medium), trigger: editing) { _, new in new }
    }

    @ViewBuilder
    private var content: some View {
        switch widget {
        case .whisper: WhisperWidget()
        case .days: DaysWidget()
        case .todo: TodoProgressWidget()
        case .diary: DiaryWidget()
        case .countdown: CountdownWidget()
        case .mood: MoodWidget()
        case .memory: MemoryWidget()
        }
    }
}

// MARK: - 小组件

private struct SmallWidget<Content: View>: View {
    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading) {
            Text(caption).font(Typo.serif(13)).foregroundStyle(Palette.inkSoft)
            Spacer(minLength: 0)
            content
        }
        .padding(Space.card)
        .frame(maxWidth: .infinity, minHeight: 136, maxHeight: 136, alignment: .leading)
        .card()
    }
}

private struct WhisperWidget: View {
    @AppStorage(Prefs.whisperText) private var text = ""
    @AppStorage(Prefs.whisperAuthor) private var author = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.card) {
            Label("today's whisper", systemImage: "sparkle")
                .font(Typo.serif(13))
                .foregroundStyle(Palette.onNoir.opacity(0.6))
            Text(text.isEmpty ? "连上电脑后，Claude 每天会在这里留一句话给你。" : text)
                .font(Typo.serif(20))
                .lineSpacing(6)
                .foregroundStyle(Palette.onNoir)
                .fixedSize(horizontal: false, vertical: true)
            if !author.isEmpty {
                Text("— \(author)")
                    .font(Typo.serif(13).italic())
                    .foregroundStyle(Palette.onNoir.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.noir, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 10)
    }
}

private struct DaysWidget: View {
    @Query(sort: \Persona.createdAt) private var personas: [Persona]
    @Query(sort: \Message.createdAt) private var messages: [Message]

    private var start: Date {
        min(messages.first?.createdAt ?? .now, personas.first?.createdAt ?? .now)
    }

    var body: some View {
        let days = (Calendar.current.dateComponents([.day], from: start.startOfDay, to: Date.now.startOfDay).day ?? 0) + 1
        SmallWidget(caption: "us") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Day \(days)").font(Typo.display(32)).tracking(-0.5).foregroundStyle(Palette.ink)
                Text("从 \(Fmt.ymd.string(from: start)) 开始").font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
            }
        }
    }
}

private struct TodoProgressWidget: View {
    @Query private var items: [TodoItem]

    var body: some View {
        let start = Date.now.startOfDay, end = start.adding(days: 1)
        let today = items.filter { item in
            if item.isDone { return (item.completedAt ?? .distantPast) >= start }
            return (item.dueDate ?? .distantPast) < end
        }
        let done = today.filter(\.isDone).count
        let next = today.filter { !$0.isDone }.sorted(by: TodoItem.order).first
        SmallWidget(caption: "today") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: Space.item) {
                    ZStack {
                        Circle().stroke(Palette.fill, lineWidth: 5)
                        Circle()
                            .trim(from: 0, to: today.isEmpty ? 0 : CGFloat(done) / CGFloat(today.count))
                            .stroke(Palette.ink, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(done)/\(today.count)").font(Typo.serif(15)).foregroundStyle(Palette.ink)
                    }
                    .frame(width: 50, height: 50)
                    Text("件待办\n完成了").font(.system(size: 13)).foregroundStyle(Palette.ink)
                }
                Text(next.map { "下一件 · \($0.title)" } ?? "今天都做完了")
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSoft).lineLimit(1)
            }
        }
    }
}

private struct DiaryWidget: View {
    @Query(sort: \DiaryEntry.day, order: .reverse) private var entries: [DiaryEntry]
    @Query(sort: \Persona.createdAt) private var personas: [Persona]

    var body: some View {
        let entry = entries.first { $0.author == .ai && !$0.text.isEmpty && $0.text != "……" }
        let name = entry?.personaID.flatMap { id in personas.first { $0.id == id }?.name } ?? personas.first?.name ?? "Claude"
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack(spacing: Space.tight) {
                Text("\(name) 的日记").font(Typo.serif(17, .medium)).foregroundStyle(Palette.ink)
                if let mood = entry?.mood, !mood.isEmpty { MoodTag(text: mood) }
                Spacer()
                Chevron()
            }
            Text(entry?.text ?? "今晚 8 点以后，\(name) 会根据你们的聊天写下今天的日记。")
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(Palette.ink2)
                .lineLimit(2)
        }
        .padding(Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct MoodTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(Palette.fill, in: Capsule())
    }
}

private struct CountdownWidget: View {
    @Query(filter: #Predicate<TodoItem> { !$0.isDone }) private var items: [TodoItem]

    var body: some View {
        let tomorrow = Date.now.startOfDay.adding(days: 1)
        let next = items.filter { ($0.dueDate ?? .distantPast) >= tomorrow }.min { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        let days = next?.dueDate.map { Calendar.current.dateComponents([.day], from: Date.now.startOfDay, to: $0.startOfDay).day ?? 0 }
        SmallWidget(caption: "countdown") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(days.map(String.init) ?? "–").font(Typo.display(38)).foregroundStyle(Palette.ink)
                    Text("天").font(.system(size: 13)).foregroundStyle(Palette.ink)
                }
                Text(next.map { "距离 \($0.title)" } ?? "没有即将到来的事")
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSoft).lineLimit(1)
            }
        }
    }
}

private struct MoodWidget: View {
    @Query(sort: \DiaryEntry.day, order: .reverse) private var entries: [DiaryEntry]

    var body: some View {
        let recent = Array(entries.filter { !$0.mood.isEmpty }.prefix(5).reversed())
        SmallWidget(caption: "this week") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { i, e in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(i == recent.count - 1 ? Palette.ink : Color(hex: MoodWidget.tint(e.mood)))
                            .frame(height: 46 * MoodWidget.height(e.mood))
                    }
                    if recent.isEmpty {
                        Text("还没有心情记录").font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
                    }
                }
                .frame(height: 46, alignment: .bottom)
                Text(recent.last.map { "最近的心情 · \($0.mood)" } ?? " ").font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
            }
        }
    }

    static func height(_ mood: String) -> CGFloat {
        if ["开心", "兴奋", "惬意", "满足"].contains(mood) { return 0.95 }
        if ["平静", "安心", "温柔"].contains(mood) { return 0.7 }
        if ["累了", "疲惫", "无聊"].contains(mood) { return 0.45 }
        return 0.3
    }

    static func tint(_ mood: String) -> UInt32 {
        let h = height(mood)
        return h > 0.9 ? 0xD8C5AE : h > 0.6 ? 0xB7C3B1 : 0xAEBFCE
    }
}

private struct MemoryWidget: View {
    @Query(filter: #Predicate<Attachment> { $0.kindRaw == "image" }) private var images: [Attachment]

    var body: some View {
        let pick = images.last
        ZStack(alignment: .bottomLeading) {
            if let pick, let image = cachedImage(pick.data, key: pick.id.uuidString) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Palette.fill
                Image(systemName: "photo").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("memory").font(Typo.serif(13).italic()).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 4)
                .padding(14)
        }
        .frame(maxWidth: .infinity, minHeight: 136, maxHeight: 136)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 14, y: 5)
    }
}

private struct WidgetGallery: View {
    let added: Set<HomeWidget>
    let onAdd: (HomeWidget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            Text("小组件").font(Typo.serif(20, .medium)).foregroundStyle(Palette.ink).padding(.horizontal, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(HomeWidget.allCases) { w in
                    let isAdded = added.contains(w)
                    Button { if !isAdded { onAdd(w) } } label: {
                        VStack(spacing: Space.tight) {
                            Image(systemName: w.symbol)
                                .font(.system(size: 19))
                                .foregroundStyle(Palette.ink)
                                .frame(width: 44, height: 44)
                                .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            Text(w.label).font(.system(size: 13)).foregroundStyle(Palette.ink)
                            Text(isAdded ? "已添加" : (w.wide ? "宽" : "小")).font(.system(size: 11)).foregroundStyle(Palette.inkSoft)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.item)
                        .card(radius: Radius.tile)
                        .opacity(isAdded ? 0.45 : 1)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .disabled(isAdded)
                }
            }
        }
        .padding(.horizontal, Space.card)
        .padding(.top, 24)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
