import SwiftUI
import SwiftData
import PhotosUI

struct PersonasView: View {
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @Query(filter: #Predicate<Conversation> { $0.isGroup }, sort: \Conversation.createdAt) private var groups: [Conversation]
    @State private var newGroup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                VStack(alignment: .leading, spacing: Space.tight) {
                    SectionLabel(text: "角色")
                    VStack(spacing: 0) {
                        ForEach(personas) { p in
                            Button { router.open(.persona(p.id)) } label: {
                                HStack(spacing: Space.item) {
                                    AvatarView(persona: p, size: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(p.name).font(Typo.serif(16.5, .medium)).foregroundStyle(Palette.ink)
                                            EngineLogo(engine: p.engine, size: 12)
                                        }
                                        if !p.bio.isEmpty {
                                            Text(p.bio).font(.system(size: 13)).foregroundStyle(Palette.inkSoft).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Chevron()
                                }
                                .padding(.horizontal, Space.card)
                                .frame(height: Space.rowTall + 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableRowStyle())
                            if p.id != personas.last?.id { Hairline(inset: 68) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .card()
                }

                if !groups.isEmpty {
                    VStack(alignment: .leading, spacing: Space.tight) {
                        SectionLabel(text: "群聊")
                        VStack(spacing: 0) {
                            ForEach(groups) { g in
                                Button { router.open(.chat(g.id)) } label: {
                                    SettingRow(title: g.displayTitle(personas.filter { g.memberIDs.contains($0.id) })) {
                                        Text("\(g.memberIDs.count) 位").font(.system(size: 13)).foregroundStyle(Palette.inkSoft)
                                        Chevron()
                                    }
                                }
                                .buttonStyle(PressableRowStyle())
                                if g.id != groups.last?.id { Hairline() }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .card()
                    }
                }

                HStack(spacing: Space.item) {
                    bigButton("新建角色", "person.badge.plus", action: createPersona)
                    bigButton("新建群聊", "person.3", action: { newGroup = true })
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .top, spacing: 0) { SubpageHeader(title: "角色") }
        .background(Palette.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $newGroup) {
            NewGroupSheet { convo in router.open(.chat(convo.id)) }
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
    }

    private func bigButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity)
                .frame(height: Space.row)
                .card()
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func createPersona() {
        let p = Persona(name: "新角色", engine: .claude, tint: 0xD8C5AE)
        p.sortIndex = (personas.map(\.sortIndex).max() ?? 0) + 1
        context.insert(p)
        _ = context.chat(for: p)
        try? context.save()
        router.open(.persona(p.id))
    }
}

struct NewGroupSheet: View {
    let onCreate: (Conversation) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @State private var title = ""
    @State private var selected: [UUID] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                HStack {
                    Button("取消") { dismiss() }.foregroundStyle(Palette.inkSoft)
                    Spacer()
                    Text("新建群聊").font(Typo.serif(18, .medium)).foregroundStyle(Palette.ink)
                    Spacer()
                    Button("创建") {
                        let convo = Conversation(title: title.trimmed, isGroup: true, memberIDs: selected)
                        context.insert(convo)
                        try? context.save()
                        dismiss()
                        onCreate(convo)
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.ink)
                    .disabled(selected.count < 2)
                }
                TextField("群聊名称", text: $title)
                    .font(.system(size: 16))
                    .padding(.horizontal, Space.card)
                    .frame(height: Space.row)
                    .card()
                VStack(spacing: 0) {
                    ForEach(personas) { p in
                        Button {
                            if let i = selected.firstIndex(of: p.id) { selected.remove(at: i) } else { selected.append(p.id) }
                        } label: {
                            HStack(spacing: Space.item) {
                                AvatarView(persona: p, size: 36)
                                Text(p.name).font(.system(size: 16)).foregroundStyle(Palette.ink)
                                Spacer()
                                Image(systemName: selected.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 21))
                                    .foregroundStyle(selected.contains(p.id) ? Palette.ink : Palette.faint)
                            }
                            .padding(.horizontal, Space.card)
                            .frame(height: Space.row + 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableRowStyle())
                        if p.id != personas.last?.id { Hairline(inset: 64) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .card()
                .sensoryFeedback(.selection, trigger: selected)
            }
            .padding(Space.page)
        }
    }
}

struct PersonaEditor: View {
    @Bindable var persona: Persona
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(RelayClient.self) private var relay
    @State private var photoItem: PhotosPickerItem?
    @State private var confirmDelete = false
    @State private var confirmClear = false
    @State private var chat: Conversation?
    @State private var pickingVoice = false
    @State private var pickingModel = false
    @State private var tuning = false
    /// 约定存在本机设置里：读这个让列表跟着变
    @AppStorage(Prefs.appointments) private var appointmentsRaw = ""

    /// TA 答应你的事（到点来找你）
    private var appointments: [Appointment] {
        _ = appointmentsRaw
        return Appointments.all.filter { $0.personaID == persona.id }.sorted { $0.at < $1.at }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                avatarSection

                // 是谁
                SettingsGroup(title: "资料") {
                    inputRow("名字", text: $persona.name)
                    Hairline()
                    inputRow("简介", text: $persona.bio)
                }

                SettingsGroup(title: "人设") {
                    TextField("TA 的性格、说话方式、记得关于你的事…", text: $persona.systemPrompt, axis: .vertical)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .lineLimit(3...12)
                        .padding(Space.card)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 语音：TA 打字的语言跟着 App 界面走，这里只管 TA 发语音时说哪种话
                if Voice.isConfigured && !persona.canWork {
                    SettingsGroup(title: "语音") {
                        // 用哪家：每家的声音和模型不一样，换了就重新选声音
                        SettingRow(title: "服务") {
                            Segmented(items: VoiceProvider.allCases.map { ($0.rawValue, $0.label) },
                                      selection: Binding(get: { persona.voiceProvider }, set: { new in
                                          guard new != persona.voiceProvider else { return }
                                          persona.voiceProvider = new
                                          persona.voiceID = ""
                                          persona.voiceName = ""
                                          persona.voiceModel = ""
                                      }))
                                .fixedSize()
                        }
                        Hairline()
                        Button { pickingVoice = true } label: {
                            SettingRow(title: "声音") {
                                Text(persona.voiceName.isEmpty ? "未选择" : persona.voiceName)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Palette.inkSoft)
                                    .lineLimit(1)
                                Chevron()
                            }
                        }
                        .buttonStyle(PressableRowStyle())
                        .disabled(!Voice.isConfigured(Voice.provider(of: persona)))
                        if !persona.voiceID.isEmpty {
                            Hairline()
                            Button { pickingModel = true } label: {
                                SettingRow(title: "模型", subtitle: voiceModelNote) {
                                    Text(voiceModelName)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Palette.inkSoft)
                                        .lineLimit(1)
                                    Chevron()
                                }
                            }
                            .buttonStyle(PressableRowStyle())
                            .transition(.opacity)
                            Hairline()
                            Button { tuning = true } label: {
                                SettingRow(title: "声音调节") {
                                    Text(tuneSummary)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Palette.inkSoft)
                                        .lineLimit(1)
                                    Chevron()
                                }
                            }
                            .buttonStyle(PressableRowStyle())
                            .transition(.opacity)
                            Hairline()
                            SettingRow(title: "发语音") {
                                Segmented(items: [(0, "不发"), (1, "偶尔"), (2, "常常")], selection: $persona.voiceFreq)
                                    .fixedSize()
                            }
                            .transition(.opacity)
                            Hairline()
                            SettingRow(title: "语音语言") {
                                Segmented(items: [("zh", "中文"), ("ko", "한국어")], selection: $persona.language)
                                    .fixedSize()
                            }
                            .transition(.opacity)
                            Hairline()
                            SettingRow(title: "自动翻译语音") {
                                InkToggle(isOn: $persona.autoTranslate, label: "自动翻译语音")
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(Motion.spring, value: persona.voiceID)
                    .animation(Motion.spring, value: persona.voiceProvider)
                }

                // 怎么互动
                SettingsGroup(title: "互动") {
                    SettingRow(title: "主动找我聊天") { InkToggle(isOn: $persona.proactive, label: "主动找我聊天") }
                    if persona.proactive {
                        Hairline()
                        SettingRow(title: "多久一次") {
                            Segmented(items: [(0, "偶尔"), (1, "每天"), (2, "常常")], selection: $persona.proactiveFreq)
                                .fixedSize()
                        }
                        .transition(.opacity)
                    }
                    Hairline()
                    SettingRow(title: "没回消息会来追问") {
                        Menu {
                            ForEach([1, 2, 3, 0], id: \.self) { option in
                                Button {
                                    persona.followUp = option
                                } label: {
                                    let title = Self.followUpLabel(option)
                                    if persona.followUp == option { Label(title, systemImage: "checkmark") } else { Text(title) }
                                }
                            }
                        } label: {
                            MenuValue(text: Self.followUpLabel(persona.followUp))
                        }
                    }
                }
                .animation(Motion.spring, value: persona.proactive)

                if !appointments.isEmpty {
                    SettingsGroup(title: "约定") {
                        ForEach(appointments) { a in
                            SettingRow(title: Appointments.label(for: a)) {
                                Button {
                                    withAnimation(Motion.spring) { Appointments.remove(a, context: context) }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Palette.inkSoft)
                                        .frame(width: 28, height: 28)
                                        .background(Palette.fill, in: Circle())
                                }
                                .accessibilityLabel("取消这个约定")
                            }
                            if a.id != appointments.last?.id { Hairline() }
                        }
                    }
                    .transition(.opacity)
                }

                // 用什么模型
                SettingsGroup(title: "模型") {
                    SettingRow(title: "由谁驱动") {
                        Segmented(items: Engine.allCases.map { ($0, $0.label) }, selection: $persona.engine)
                            .fixedSize()
                    }
                    Hairline()
                    SettingRow(title: "模型") {
                        Menu {
                            Button("跟随默认") { persona.model = "" }
                            ForEach(models) { m in
                                Button(m.name) { persona.model = m.id }
                            }
                        } label: {
                            MenuValue(text: persona.model.isEmpty ? "跟随默认" : ModelNames.name(persona.model, engine: persona.engine, status: relay.status))
                        }
                    }
                    Hairline()
                    SettingRow(title: "推理强度") {
                        EffortMenu(options: ModelNames.efforts(for: persona.model, engine: persona.engine, status: relay.status),
                                   selection: $persona.effort)
                    }
                    Hairline()
                    SettingRow(title: "允许操作电脑", subtitle: "只在电脑的「絮语工作区」里读写文件、运行命令") {
                        InkToggle(isOn: $persona.canWork, label: "允许操作电脑")
                    }
                }

                // 这段聊天
                if let chat {
                    MemoryEditor(memory: Binding(get: { chat.memory }, set: { chat.memory = $0 }))
                    SettingsGroup(title: "聊天背景") {
                        WallpaperPicker(owner: chat.id)
                            .padding(Space.card)
                    }
                }

                SettingsGroup(title: "管理") {
                    Button { confirmClear = true } label: {
                        SettingRow(title: "清空聊天记录") { EmptyView() }
                    }
                    .buttonStyle(PressableRowStyle())
                    Hairline()
                    Button { confirmDelete = true } label: {
                        Text("删除角色")
                            .font(.system(size: 16))
                            .foregroundStyle(Palette.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.card)
                            .frame(height: Space.row)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableRowStyle())
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) {
            SubpageHeader(title: "编辑角色") {
                Button("完成") { dismiss() }.font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
            }
        }
        .background(Palette.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    persona.avatarData = ImageUtil.downscale(data, maxSide: 400)
                }
                photoItem = nil
            }
        }
        .sheet(isPresented: $pickingVoice) {
            VoicePicker(persona: persona)
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        .sheet(isPresented: $tuning) {
            VoiceTuneSheet(persona: persona)
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        .sheet(isPresented: $pickingModel) {
            VoiceModelPicker(persona: persona)
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        .onAppear { chat = context.chat(for: persona) }
        .onDisappear {
            if persona.name.trimmed.isEmpty { persona.name = "未命名" }
            try? context.save()
        }
        .confirmationDialog("清空和 \(persona.name) 的聊天记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                let convo = context.chat(for: persona)
                for m in convo.messages ?? [] { context.delete(m) }
                Memory.reset(convo)
                try? context.save()
            }
        }
        .confirmationDialog("删除「\(persona.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: deletePersona)
        } message: {
            Text("和 TA 的单聊记录会一起删除。")
        }
    }

    /// 「声音调节」那一行右边：调过的才写出来，都是默认就显示「默认」
    private var tuneSummary: String {
        var parts: [String] = []
        if abs(persona.voiceSpeed - 1) > 0.01 { parts.append(String(format: "%.2g×", persona.voiceSpeed)) }
        if persona.voicePitch != 0 { parts.append(persona.voicePitch > 0 ? "+\(persona.voicePitch)" : "\(persona.voicePitch)") }
        if let e = Voice.emotions.first(where: { $0.0 == persona.voiceEmotion }), !e.0.isEmpty { parts.append(String(localized: String.LocalizationValue(e.1))) }
        return parts.isEmpty ? String(localized: "默认") : parts.joined(separator: " · ")
    }

    /// 角色页「模型」那一行：现在用的语音模型和它的侧重点
    private var voiceModelName: String {
        persona.voiceModel.isEmpty ? Voice.provider(of: persona).defaultModel : persona.voiceModel
    }

    private var voiceModelNote: String? {
        let note = Voice.modelNote(voiceModelName)
        return note.isEmpty ? nil : note
    }

    static func followUpLabel(_ setting: Int) -> String {
        switch setting {
        case 0: "不追问"
        case 2: "1～3 小时"
        case 3: "3～6 小时"
        default: "20 分钟～1 小时"
        }
    }

    private var models: [ModelInfo] {
        relay.status?.catalog(for: persona.engine) ?? []
    }

    private var avatarSection: some View {
        VStack(spacing: Space.item) {
            AvatarView(persona: persona, size: 92)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                .overlay(alignment: .bottomTrailing) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Image(systemName: "camera")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Palette.inkInverse)
                            .frame(width: 34, height: 34)
                            .background(Palette.ink, in: Circle())
                            .overlay(Circle().strokeBorder(Palette.paper, lineWidth: 2))
                    }
                    .accessibilityLabel("从相册选择头像")
                    .offset(x: 2, y: 2)
                }
            HStack(spacing: 10) {
                ForEach(Palette.avatarTints, id: \.self) { hex in
                    let on = persona.avatarData == nil && UInt32(truncatingIfNeeded: persona.tint) == hex
                    Button {
                        withAnimation(Motion.spring) {
                            persona.avatarData = nil
                            persona.tint = Int(hex)
                        }
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(on ? Palette.ink : Palette.hairline, lineWidth: on ? 2.5 : 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .sensoryFeedback(.selection, trigger: persona.tint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.tight)
    }

    private func inputRow(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: Space.item) {
            Text(label).font(.system(size: 15)).foregroundStyle(Palette.inkSoft).frame(width: 56, alignment: .leading)
            TextField(label, text: text).font(.system(size: 16)).foregroundStyle(Palette.ink)
        }
        .padding(.horizontal, Space.card)
        .frame(height: Space.row)
    }

    private func deletePersona() {
        let id = persona.id
        let convos = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        for c in convos where c.memberIDs.contains(id) {
            if c.isGroup {
                c.memberIDs.removeAll { $0 == id }
            } else {
                context.delete(c)
            }
        }
        dismiss()
        let target = persona
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            context.delete(target)
            try? context.save()
        }
    }
}
