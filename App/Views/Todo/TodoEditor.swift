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
    @Environment(RelayClient.self) private var relay
    @AppStorage(Prefs.diaryWriter) private var writerID = ""
    @AppStorage(Prefs.showMyDiary) private var showMine = true
    @State private var myText = ""
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var shortHeight: CGFloat = 0
    @FocusState private var focused: Bool

    static let moods = ["开心", "惬意", "平静", "累了", "低落"]

    private var dayEntries: [DiaryEntry] { entries.filter { $0.day == day.startOfDay } }
    /// 显示你选的那位角色写的日记；以前的日子如果 TA 没写，就显示当天别人写的
    private var aiEntry: DiaryEntry? {
        let ai = dayEntries.filter { $0.author == .ai && $0.text != "……" }
        if let mine = ai.first(where: { $0.personaID == writer?.id }) { return mine }
        return Calendar.current.isDateInToday(day) ? nil : ai.first
    }
    private var myEntry: DiaryEntry? { dayEntries.first { $0.author == .me } }
    /// 写日记的角色：你选的那位，没选就是第一位
    private var writer: Persona? { personas.first { $0.id.uuidString == writerID } ?? personas.first }
    private var aiName: String {
        aiEntry?.personaID.flatMap { id in personas.first { $0.id == id }?.name } ?? writer?.name ?? "Claude"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: Space.tight) {
                Text("Diary").font(Typo.serif(20, .semibold)).foregroundStyle(Palette.ink)
                if tab == .ai, let mood = aiEntry?.mood, !mood.isEmpty { MoodTag(text: mood) }
                if tab == .me, let mood = myEntry?.mood, !mood.isEmpty { MoodTag(text: mood) }
                Spacer()
                if showMine {
                    Segmented(items: [(DiaryAuthor.ai, aiName), (DiaryAuthor.me, "我")], selection: $tab)
                        .fixedSize()
                        .transition(.opacity)
                }
                options
            }
            if tab == .ai {
                foldingText(aiEntry?.text ?? placeholder, color: aiEntry == nil ? Palette.inkSoft : Palette.ink)
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
                                .font(.system(size: Typo.secondary))
                                .foregroundStyle(on ? Palette.inkInverse : Palette.ink2)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(on ? Palette.ink : Palette.paper, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .sensoryFeedback(.selection, trigger: myEntry?.mood)
                replyView
            }
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, Space.item)
        .card()
        .animation(Motion.spring, value: tab)
        .onAppear { myText = myEntry?.text ?? "" }
        // 看到今天的日记还没写、又已经过了 8 点：马上去写（不用等下次打开 App）
        .task(id: "\(day.timeIntervalSince1970)-\(writerID)-\(relay.isConnected)") {
            guard Calendar.current.isDateInToday(day), aiEntry == nil,
                  Calendar.current.component(.hour, from: .now) >= 20 else { return }
            await Companion.writeDiaries(context: context, relay: relay)
        }
        .onChange(of: day) { _, _ in
            myText = myEntry?.text ?? ""
            expanded = false
        }
    }

    /// 日记正文：平时显示三行，点一下高度平滑地长出全文（下面的内容被柔和地推开），再点一下缩回去。
    /// 收起时最后一行轻轻淡出，提示还有下文
    private func foldingText(_ text: String, color: Color) -> some View {
        let canFold = fullHeight > shortHeight + 1
        let folded = canFold && !expanded
        return Text(text)
            .font(.system(size: 15))
            .lineSpacing(6)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            .background(alignment: .top) {
                // 量一下三行有多高
                Text(text)
                    .font(.system(size: 15))
                    .lineSpacing(6)
                    .lineLimit(3)
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
                        .frame(height: 22)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard canFold else { return }
                withAnimation(Motion.spring) { expanded.toggle() }
            }
            .sensoryFeedback(.selection, trigger: expanded)
    }

    /// 你的日记下面：TA 的回信，像交换日记一样
    @ViewBuilder
    private var replyView: some View {
        if let entry = myEntry, DiaryState.shared.replying.contains(entry.id) {
            HStack(spacing: Space.tight) {
                AvatarView(persona: writer, size: 22)
                Text("\(writer?.name ?? "TA") 正在回信").font(.system(size: Typo.secondary)).foregroundStyle(Palette.inkSoft)
                TypingDots().scaleEffect(0.7, anchor: .leading)
            }
            .padding(.top, 4)
            .transition(.opacity)
        } else if let entry = myEntry, !entry.reply.isEmpty {
            let author = personas.first { $0.id == entry.replyPersonaID } ?? writer
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    AvatarView(persona: author, size: 22)
                    Text("\(author?.name ?? "TA") 的回信").font(Typo.serif(13)).foregroundStyle(Palette.inkSoft)
                }
                Text(entry.reply)
                    .font(Typo.serif(15))
                    .lineSpacing(6)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.item)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .padding(.top, 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// 日记的选项：由哪位角色来写、要不要显示自己的日记
    private var options: some View {
        Menu {
            Section("由谁来写日记") {
                ForEach(personas) { p in
                    Button {
                        writerID = p.id.uuidString
                    } label: {
                        if p.id == writer?.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                }
            }
            Button {
                withAnimation(Motion.spring) {
                    showMine.toggle()
                    if !showMine { tab = .ai }
                }
            } label: {
                if showMine { Label("显示我的日记", systemImage: "checkmark") } else { Text("显示我的日记") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.inkSoft)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("日记选项")
    }

    private var placeholder: String {
        if DiaryState.shared.writing.contains(day.startOfDay) { return "\(aiName) 正在写今天的日记…" }
        guard Calendar.current.isDateInToday(day) else { return "这一天没有日记。" }
        if Calendar.current.component(.hour, from: .now) < 20 {
            return "今晚 8 点以后，\(aiName) 会根据你们的聊天写下今天的日记。"
        }
        if !Companion.enoughToWrite(on: day, context: context) && myEntry == nil {
            return "今天聊得还不多，多聊几句，\(aiName) 就会写下今天的日记。"
        }
        return relay.isConnected ? "\(aiName) 马上就会写好今天的日记。" : "连上电脑后，\(aiName) 就会写好今天的日记。"
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
        let entry = ensureMine()
        entry.text = text
        try? context.save()
        // 写完（或改了）就请 TA 回信
        guard let writer, text.count >= 6, text != entry.repliedText else { return }
        Task { await Companion.replyToDiary(entry, by: writer, context: context, relay: relay) }
    }

    private func setMood(_ mood: String) {
        let entry = ensureMine()
        entry.mood = entry.mood == mood ? "" : mood
        entry.text = myText.trimmed
        try? context.save()
    }
}
