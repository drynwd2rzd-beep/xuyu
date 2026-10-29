import SwiftUI
import SwiftData
import PhotosUI

enum HomeWidget: String, CaseIterable, Identifiable {
    case whisper, moments, days, todo, diary, countdown, mood, memory, photo

    var id: String { rawValue }
    var wide: Bool { self == .whisper || self == .diary || self == .moments }

    var label: String {
        switch self {
        case .whisper: "今日一句"
        case .moments: "动态"
        case .days: "在一起"
        case .todo: "今日待办"
        case .diary: "日记"
        case .countdown: "倒数日"
        case .mood: "心情"
        case .memory: "回忆"
        case .photo: "照片"
        }
    }

    var symbol: String {
        switch self {
        case .whisper: "sparkle"
        case .moments: "photo.on.rectangle.angled"
        case .days: "heart"
        case .todo: "checklist"
        case .diary: "book.closed"
        case .countdown: "hourglass"
        case .mood: "chart.bar"
        case .memory: "photo.stack"
        case .photo: "photo"
        }
    }

    static let defaults: [HomeWidget] = [.whisper, .moments, .days, .todo, .diary]
}

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @AppStorage(Prefs.homeWidgets) private var widgetsRaw = HomeWidget.defaults.map(\.rawValue).joined(separator: ",")
    @AppStorage(Prefs.nickname) private var nickname = ""
    @State private var showGallery = false
    @State private var pickPhoto = false
    @State private var photoItem: PhotosPickerItem?

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
                    // 小组件全删光了：留一个空位，点它就能再加回来。编辑只能靠长按某个小组件进入，
                    // 一个都不剩时就没有东西可以长按，以前会再也加不回来
                    if widgets.isEmpty && !editing {
                        Button {
                            setEditing(true)
                            showGallery = true
                        } label: {
                            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                .strokeBorder(Palette.inkSoft.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                .frame(height: 96)
                                .overlay {
                                    Image(systemName: "plus").font(.system(size: 20, weight: .light)).foregroundStyle(Palette.inkSoft)
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .accessibilityLabel("添加小组件")
                        .transition(.opacity)
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
                        .background {
                            Capsule().fill(.ultraThinMaterial).shadow(color: .black.opacity(0.09), radius: 18, y: 8)
                        }
                        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
                }
                .buttonStyle(ScaleButtonStyle())
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear(perform: addMomentsOnce)
        .sheet(isPresented: $showGallery) {
            WidgetGallery(added: Set(widgets)) { add($0) }
                .presentationDetents([.height(500), .large])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        .photosPicker(isPresented: $pickPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    withAnimation(Motion.spring) { WidgetPhotoStore.save(data) }
                }
                photoItem = nil
            }
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
        // 刚加上照片组件、还没有照片时，直接让你选一张
        if widget == .photo, WidgetPhotoStore.image == nil {
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                pickPhoto = true
            }
        }
    }

    /// 动态是后来才有的：已经在用的人，主页上自动加一次（放在今日一句后面）；之后删了就不再加
    private func addMomentsOnce() {
        guard !UserDefaults.standard.bool(forKey: Prefs.momentsWidgetAdded) else { return }
        UserDefaults.standard.set(true, forKey: Prefs.momentsWidgetAdded)
        guard !widgets.contains(.moments) else { return }
        var list = widgets
        list.insert(.moments, at: list.firstIndex(of: .whisper).map { $0 + 1 } ?? 0)
        widgetsRaw = list.map(\.rawValue).joined(separator: ",")
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
        case .photo:
            pickPhoto = true
        case .moments:
            router.open(.moments)
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
        case .moments: MomentsWidget()
        case .days: DaysWidget()
        case .todo: TodoProgressWidget()
        case .diary: DiaryWidget()
        case .countdown: CountdownWidget()
        case .mood: MoodWidget()
        case .memory: MemoryWidget()
        case .photo: PhotoWidget()
        }
    }
}

private struct WidgetGallery: View {
    let added: Set<HomeWidget>
    let onAdd: (HomeWidget) -> Void

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: Space.section) {
            Text("小组件").font(Typo.serif(20, .medium)).foregroundStyle(Palette.ink).padding(.horizontal, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.item), count: 3), spacing: Space.item) {
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
        .padding(.top, 28)
        .padding(.bottom, Space.page)
        }
        .scrollIndicators(.hidden)
    }
}
