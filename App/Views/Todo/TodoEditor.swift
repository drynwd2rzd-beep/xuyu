import SwiftUI
import SwiftData

struct TodoEditor: View {
    @Bindable var item: TodoItem
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var deleted = false
    @State private var denied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                HStack {
                    Button("删除", role: .destructive) {
                        deleted = true
                        Reminders.cancel(item)
                        dismiss()
                        let target = item
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            context.delete(target)
                            try? context.save()
                        }
                    }
                    .foregroundStyle(Palette.danger)
                    Spacer()
                    Button("完成") { dismiss() }.fontWeight(.semibold).foregroundStyle(Palette.ink)
                }
                .font(.system(size: 16))

                VStack(alignment: .leading, spacing: 0) {
                    TextField("要做的事", text: $item.title, axis: .vertical)
                        .font(Typo.serif(19))
                        .padding(Space.card)
                    Hairline()
                    TextField("备注", text: $item.notes, axis: .vertical)
                        .font(.system(size: 15))
                        .lineLimit(2...6)
                        .padding(Space.card)
                }
                .card()

                VStack(spacing: 0) {
                    SettingRow(title: "日期") {
                        Toggle("", isOn: dateBinding).labelsHidden().tint(Palette.ink)
                    }
                    if item.dueDate != nil {
                        Hairline()
                        SettingRow(title: "哪一天") {
                            DatePicker("", selection: dueBinding, displayedComponents: .date).labelsHidden()
                        }
                        Hairline()
                        SettingRow(title: "具体时间") {
                            Toggle("", isOn: timeBinding).labelsHidden().tint(Palette.ink)
                        }
                        if item.hasTime {
                            Hairline()
                            SettingRow(title: "几点") {
                                DatePicker("", selection: dueBinding, displayedComponents: .hourAndMinute).labelsHidden()
                            }
                        }
                        Hairline()
                        SettingRow(title: "提醒我", subtitle: item.remind && !item.hasTime ? "当天上午 9:00" : nil) {
                            Toggle("", isOn: remindBinding).labelsHidden().tint(Palette.ink)
                        }
                        if item.remind && item.hasTime {
                            Hairline()
                            SettingRow(title: "提前") {
                                Picker("", selection: $item.remindLead) {
                                    Text("准时").tag(0)
                                    Text("5 分钟").tag(5)
                                    Text("10 分钟").tag(10)
                                    Text("30 分钟").tag(30)
                                    Text("1 小时").tag(60)
                                }
                                .labelsHidden()
                                .tint(Palette.ink2)
                            }
                        }
                    }
                }
                .card()
                .animation(Motion.spring, value: item.dueDate != nil)
                .animation(Motion.spring, value: item.hasTime)
                .animation(Motion.spring, value: item.remind)
            }
            .padding(Space.page)
        }
        .alert("需要在系统设置里允许「絮语」发送通知。", isPresented: $denied) { Button("好", role: .cancel) {} }
        .onDisappear {
            guard !deleted else { return }
            if item.title.trimmed.isEmpty { item.title = "未命名" }
            try? context.save()
            Reminders.sync(item)
        }
    }

    private var dateBinding: Binding<Bool> {
        Binding(get: { item.dueDate != nil }, set: { on in
            item.dueDate = on ? Date.now.startOfDay : nil
            if !on {
                item.hasTime = false
                item.remind = false
            }
        })
    }

    private var dueBinding: Binding<Date> {
        Binding(get: { item.dueDate ?? .now }, set: { item.dueDate = item.hasTime ? $0 : $0.startOfDay })
    }

    private var timeBinding: Binding<Bool> {
        Binding(get: { item.hasTime }, set: { on in
            item.hasTime = on
            let day = (item.dueDate ?? .now).startOfDay
            if on {
                let hour = max(Calendar.current.component(.hour, from: .now) + 1, 9)
                item.dueDate = Calendar.current.date(bySettingHour: min(hour, 21), minute: 0, second: 0, of: day)
            } else {
                item.dueDate = day
            }
        })
    }

    private var remindBinding: Binding<Bool> {
        Binding(get: { item.remind }, set: { on in
            item.remind = on
            guard on else { return }
            Task {
                if !(await Reminders.ensureAuthorized()) {
                    item.remind = false
                    denied = true
                }
            }
        })
    }
}

/// 待办页下方的日记：Claude 写的 / 自己写的
struct DiaryCard: View {
    let day: Date
    @Environment(\.modelContext) private var context
    @Query(sort: \DiaryEntry.createdAt) private var entries: [DiaryEntry]
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @State private var tab: DiaryAuthor = .ai
    @State private var myText = ""
    @State private var expanded = false
    @FocusState private var focused: Bool

    static let moods = ["开心", "惬意", "平静", "累了", "低落"]

    private var dayEntries: [DiaryEntry] { entries.filter { $0.day == day.startOfDay } }
    private var aiEntry: DiaryEntry? { dayEntries.first { $0.author == .ai && $0.text != "……" } }
    private var myEntry: DiaryEntry? { dayEntries.first { $0.author == .me } }
    private var aiName: String {
        aiEntry?.personaID.flatMap { id in personas.first { $0.id == id }?.name } ?? personas.first?.name ?? "Claude"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: Space.tight) {
                Text("Diary").font(Typo.serif(20, .semibold)).foregroundStyle(Palette.ink)
                if tab == .ai, let mood = aiEntry?.mood, !mood.isEmpty { MoodTag(text: mood) }
                if tab == .me, let mood = myEntry?.mood, !mood.isEmpty { MoodTag(text: mood) }
                Spacer()
                Segmented(items: [(DiaryAuthor.ai, aiName), (DiaryAuthor.me, "我")], selection: $tab)
                    .fixedSize()
            }
            if tab == .ai {
                Text(aiEntry?.text ?? placeholder)
                    .font(.system(size: 15))
                    .lineSpacing(6)
                    .foregroundStyle(aiEntry == nil ? Palette.inkSoft : Palette.ink)
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { withAnimation(Motion.spring) { expanded.toggle() } }
                    .transition(.opacity)
            } else {
                TextField("今天过得怎么样？随便写几句…", text: $myText, axis: .vertical)
                    .font(.system(size: 15))
                    .lineSpacing(6)
                    .lineLimit(3...10)
                    .focused($focused)
                    .onChange(of: focused) { _, f in if !f { saveMine() } }
                HStack(spacing: 6) {
                    ForEach(Self.moods, id: \.self) { mood in
                        let on = myEntry?.mood == mood
                        Button { setMood(mood) } label: {
                            Text(mood)
                                .font(.system(size: 12.5))
                                .foregroundStyle(on ? Palette.inkInverse : Palette.ink2)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(on ? Palette.ink : Palette.paper, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .sensoryFeedback(.selection, trigger: myEntry?.mood)
            }
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, Space.item)
        .card()
        .animation(Motion.spring, value: tab)
        .onAppear { myText = myEntry?.text ?? "" }
        .onChange(of: day) { _, _ in
            myText = myEntry?.text ?? ""
            expanded = false
        }
    }

    private var placeholder: String {
        Calendar.current.isDateInToday(day) ? "今晚 8 点以后，\(aiName) 会根据你们的聊天写下今天的日记。" : "这一天没有日记。"
    }

    private func ensureMine() -> DiaryEntry {
        if let myEntry { return myEntry }
        let entry = DiaryEntry(day: day, author: .me, text: "")
        context.insert(entry)
        return entry
    }

    private func saveMine() {
        let text = myText.trimmed
        guard !text.isEmpty || myEntry != nil else { return }
        ensureMine().text = text
        try? context.save()
    }

    private func setMood(_ mood: String) {
        let entry = ensureMine()
        entry.mood = entry.mood == mood ? "" : mood
        entry.text = myText.trimmed
        try? context.save()
    }
}
