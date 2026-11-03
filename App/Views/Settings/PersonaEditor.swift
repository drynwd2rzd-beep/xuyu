import SwiftUI
import SwiftData
import PhotosUI

/// 编辑角色的五章。和 TA 有关的每一项设置只在一章里出现：
/// 灵魂 = TA 是谁、怎么说话；记忆 = TA 记得什么、你们的关系；生活 = TA 自己怎么过日子、发什么动态；
/// 习惯 = TA 怎么找你、像不像真人；底层 = 用什么模型驱动，和这段聊天的管理
enum PersonaChapter: CaseIterable {
    case soul, memory, life, habits, engine

    var title: String {
        switch self {
        case .soul: "灵魂"
        case .memory: "记忆"
        case .life: "生活"
        case .habits: "习惯"
        case .engine: "底层"
        }
    }

    /// 章名上面的小字，只做装饰，不翻译（NAME-6）
    var latin: String {
        switch self {
        case .soul: "Anima"
        case .memory: "Memoria"
        case .life: "Vita"
        case .habits: "Mores"
        case .engine: "Machina"
        }
    }
}

/// 编辑角色：顶上切换五章，下面是这一章的设置
struct PersonaEditor: View {
    @Bindable var persona: Persona
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatEngine.self) private var engine
    @Environment(Router.self) private var router
    @State private var chapter: PersonaChapter = .soul
    @State private var photoItem: PhotosPickerItem?
    @State private var confirmDelete = false
    @State private var confirmClear = false
    @State private var chat: Conversation?
    /// 约定存在本机设置里：读这个让列表跟着变
    @AppStorage(Prefs.appointments) private var appointmentsRaw = ""

    /// TA 答应你的事（到点来找你）
    private var appointments: [Appointment] {
        _ = appointmentsRaw
        return Appointments.all.filter { $0.personaID == persona.id }.sorted { $0.at < $1.at }
    }

    /// 工作模式的角色不过日子：没有「生活」这一章
    private var chapters: [PersonaChapter] {
        persona.canWork ? PersonaChapter.allCases.filter { $0 != .life } : PersonaChapter.allCases
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                ChapterBar(chapters: chapters, selection: $chapter)
                // 换章：旧的一章直接撤掉，新的一章轻轻浮上来（叠在一起淡入淡出会糊）
                ZStack(alignment: .top) {
                    chapterContent
                        .id(chapter)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .identity))
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
        .onAppear { chat = context.chat(for: persona) }
        .onDisappear {
            if persona.name.trimmed.isEmpty { persona.name = "未命名" }
            context.persist()
        }
        .confirmationDialog("清空和 \(persona.name) 的聊天记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                let convo = context.chat(for: persona)
                Task { await Cleanup.clearChat(convo, context: context, engine: engine) }
            }
        } message: {
            Text("角色会保留，记录删除后无法恢复。")
        }
        .confirmationDialog("删除「\(persona.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: deletePersona)
        } message: {
            Text("和 TA 的聊天、记忆、动态、相册和日记都会一起删除。")
        }
    }

    /// 这一章的内容
    private var chapterContent: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            switch chapter {
            case .soul:
                avatarSection
                profileGroup
                promptGroup
                if !persona.canWork && Voice.isConfigured { PersonaVoiceGroup(persona: persona) }
            case .memory:
                if let chat { MemoryEditor(memory: Binding(get: { chat.memory }, set: { chat.memory = $0 })) }
                appointmentsGroup
                if !persona.canWork { YouTwoGroup(persona: persona) }
            case .life:
                PersonaLifeGroups(persona: persona)
                PersonaMomentsGroups(persona: persona)
            case .habits:
                ReachOutGroup(persona: persona)
                if !persona.canWork { HumanTouchGroup(persona: persona) }
            case .engine:
                PersonaModelGroup(persona: persona)
                if let chat {
                    SettingsGroup(title: "聊天背景") {
                        WallpaperPicker(owner: chat.id)
                            .padding(Space.card)
                    }
                }
                manageGroup
            }
        }
    }

    // MARK: - 灵魂

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

    /// 资料：是谁（名字、简介）
    private var profileGroup: some View {
        SettingsGroup(title: "资料") {
            inputRow("名字", text: $persona.name)
            inputRow("简介", text: $persona.bio)
        }
    }

    /// 人设：TA 要了解的那段自我设定
    private var promptGroup: some View {
        SettingsGroup(title: "人设") {
            TextField("TA 的性格、说话方式、记得关于你的事…", text: $persona.systemPrompt, axis: .vertical)
                .font(.system(size: 15))
                .lineSpacing(5)
                .lineLimit(3...12)
                .padding(Space.card)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func inputRow(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: Space.item) {
            Text(LocalizedStringKey(label)).font(.system(size: 15)).foregroundStyle(Palette.inkSoft).frame(width: 56, alignment: .leading)
            TextField(LocalizedStringKey(label), text: text).font(.system(size: 16)).foregroundStyle(Palette.ink)
        }
        .padding(.horizontal, Space.card)
        .frame(height: Space.row)
    }

    // MARK: - 记忆

    /// 约定：TA 答应你的事，一条条列出来，可以取消；没有就不显示
    @ViewBuilder
    private var appointmentsGroup: some View {
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
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: - 底层

    /// 管理：清空聊天记录、删除角色（都会先问一次）
    private var manageGroup: some View {
        SettingsGroup(title: "管理") {
            Button { confirmClear = true } label: {
                SettingRow(title: "清空聊天记录") { EmptyView() }
            }
            .buttonStyle(PressableRowStyle())
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

    /// 先退出正在显示 TA 的页面（编辑页；从 TA 的聊天里点进来的，连聊天一起退出），等退完再删（NAV-4）。
    /// 删什么、按什么顺序删，见 Cleanup.deletePersona
    private func deletePersona() {
        let id = persona.id
        if let open = router.chat, context.conversation(open)?.memberIDs == [id] { router.closeChat() }
        dismiss()
        let target = persona
        Task {
            // 页面退回、聊天层散开都没有回调可等：等它们走完
            try? await Task.sleep(for: Motion.dismissSettle)
            await Cleanup.deletePersona(target, context: context, engine: engine)
        }
    }
}

/// 五章的切换：章名上面一行拉丁小字；选中的是墨色，其余是浅灰
private struct ChapterBar: View {
    let chapters: [PersonaChapter]
    @Binding var selection: PersonaChapter

    var body: some View {
        HStack(spacing: 22) {
            ForEach(chapters, id: \.self) { c in
                let on = c == selection
                Button {
                    withAnimation(Motion.snappy) { selection = c }
                } label: {
                    VStack(spacing: 2) {
                        Text(verbatim: c.latin).font(Typo.serif(10.5).italic())
                        Text(LocalizedStringKey(c.title)).font(.system(size: 14, weight: on ? .medium : .regular)).tracking(2.4)
                    }
                    .foregroundStyle(on ? Palette.ink : Palette.inkSoft)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.tight)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
