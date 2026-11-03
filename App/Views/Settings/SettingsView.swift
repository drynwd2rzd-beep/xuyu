import SwiftUI
import SwiftData
import PhotosUI

// MARK: - 设置首页

/// 设置首页：我（头像、称呼、你是谁）、AI（角色与群聊、世界、两个引擎的默认模型）、
/// App（电脑中继、语音服务、通知、外观、隐私、备份）、重置。每个角色自己的设置在编辑角色的五章里
struct SettingsView: View {
    @Environment(RelayClient.self) private var relay
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @AppStorage(Prefs.nickname) private var nickname = ""
    @AppStorage(Prefs.defaultClaudeModel) private var claudeModel = ""
    @AppStorage(Prefs.defaultCodexModel) private var codexModel = ""
    @AppStorage(Prefs.defaultClaudeEffort) private var claudeEffort = ""
    @AppStorage(Prefs.defaultCodexEffort) private var codexEffort = ""
    @AppStorage(Prefs.myAvatarStamp) private var avatarStamp = 0.0
    @State private var avatarItem: PhotosPickerItem?
    @State private var modelEngine: Engine?
    @State private var you = World.state.you

    var body: some View {
        ScrollView {
            sections
                .padding(.horizontal, Space.tight)
                .padding(.bottom, Space.bottom)
        }
        .scrollIndicators(.hidden)
        .background(Palette.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $modelEngine) { engine in
            ModelPicker(engine: engine,
                        selection: engine == .claude ? $claudeModel : $codexModel,
                        effort: engine == .claude ? $claudeEffort : $codexEffort,
                        status: relay.status)
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    withAnimation(Motion.spring) { _ = ImageFileStore.myAvatar.save(data) }
                }
                avatarItem = nil
            }
        }
        .onAppear { relay.refreshStatus() }
        .confirmationDialog(Text(confirming?.title ?? ""), isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { kind in
            if kind != .settings {
                Button("先备份到电脑") { router.open(.backup) }
            }
            Button(kind.action, role: .destructive) {
                // 最重的那一档再问一次
                if kind == .everything { finalCheck = true } else { reset(kind) }
            }
        } message: { kind in
            Text(kind.message)
        }
        .alert("真的全部删除吗？", isPresented: $finalCheck) {
            Button("全部删除", role: .destructive) { reset(.everything) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这一步做了就回不去了。")
        }
        .alert("没能全部删除，请再试一次。", isPresented: $resetFailed) {
            Button("好", role: .cancel) {}
        }
        .sensoryFeedback(.success, trigger: resetDone)
    }

    /// 首页的四块：我（你是谁）、AI（TA 们和驱动 TA 们的模型）、App（这台手机上的 App 本身）、重置
    private var sections: some View {
        VStack(alignment: .leading, spacing: Space.group) {
            // 照设计稿：返回，「设置 Optiones」，然后是你（头像、称呼、TA 们都知道的那段「你是谁」）
            VStack(alignment: .leading, spacing: 0) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: Icon.back, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: Space.control, height: Space.control)
                }
                .accessibilityLabel("返回")
                PageHeading(title: "设置", latin: "Optiones") { EmptyView() }
                    .padding(.horizontal, -Space.tight)
                meRow
            }

            SettingsGroup(title: "AI") {
                // 一排角色卡，点卡片直接编辑那一位；群聊、排序、删除在「角色与群聊」里
                PersonaCast()
                    .padding(.bottom, Space.tight)
                Button { router.open(.personas) } label: {
                    SettingRow(title: "角色与群聊") {
                        Text("\(personas.count) 位").font(.system(size: Typo.value)).foregroundStyle(Palette.inkSoft)
                        Chevron()
                    }
                }
                .buttonStyle(PressableRowStyle())
                // 大家共用的世界：生活的世界、天气、关系
                navRow("世界", route: .world)
                engineRow(.claude)
                engineRow(.codex)
            }

            SettingsGroup(title: "App") {
                Button { router.open(.connection) } label: {
                    connectionRow(title: "电脑中继", subtitle: relayLine, ok: relay.isConnected)
                }
                .buttonStyle(PressableRowStyle())
                navRow("语音服务", route: .voice)
                navRow("通知", route: .notifications)
                navRow("外观与背景", route: .appearance)
                navRow("隐私与安全", route: .privacy)
                navRow("备份与恢复", route: .backup)
            }

            // 从轻到重：只还原偏好 → 删掉所有角色 → 什么都删（像刚装好）
            SettingsGroup(title: "重置") {
                resetRow("还原所有设置") { confirming = .settings }
                resetRow("删除所有人设") { confirming = .personas }
                resetRow("恢复出厂设置", danger: true) { confirming = .everything }
            }
            .disabled(resetting)
        }
    }

    // MARK: - 重置

    @Environment(\.modelContext) private var context
    @Environment(ChatEngine.self) private var engine
    @State private var confirming: ResetKind?
    @State private var finalCheck = false
    @State private var resetting = false
    @State private var resetDone = 0
    @State private var resetFailed = false

    /// 重置的三档，从轻到重
    enum ResetKind: Identifiable {
        case settings, personas, everything
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .settings: "还原所有设置？"
            case .personas: "删除所有人设？"
            case .everything: "恢复出厂设置？"
            }
        }

        var action: LocalizedStringKey {
            switch self {
            case .settings: "还原"
            case .personas: "删除所有人设"
            case .everything: "全部删除"
            }
        }

        var message: LocalizedStringKey {
            switch self {
            case .settings: "外观、聊天背景、通知、默认模型、小组件这些回到默认。聊天、人设、待办都不动。"
            case .personas: "所有角色，和 TA 们的聊天、动态、相册、日记都会删掉，换回默认的 Claude 和 Codex。设置和待办不动。删了就找不回来。"
            case .everything: "所有聊天、人设、待办、表情和设置都会删掉，和电脑的配对、语音服务的密钥也会清掉，就像刚装好一样。删了就找不回来，建议先备份到电脑。"
            }
        }
    }

    private func resetRow(_ title: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(LocalizedStringKey(title)).font(.system(size: 16)).foregroundStyle(danger ? Palette.danger : Palette.ink)
                Spacer()
                if resetting && danger { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, Space.card)
            .frame(height: Space.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
    }

    private func reset(_ kind: ResetKind) {
        resetting = true
        Task {
            do {
                switch kind {
                case .settings: Reset.settings()
                case .personas: try await Reset.personas(context: context, engine: engine)
                case .everything: try await Reset.everything(context: context, engine: engine, relay: relay)
                }
            } catch {
                // 没删成：数据原样留着，告诉你再试一次（不假装完成）
                resetting = false
                resetFailed = true
                return
            }
            resetting = false
            resetDone += 1
            // 删了人设或全部删掉：回到 Today 最开始的样子
            if kind != .settings {
                router.path = NavigationPath()
                router.tab = .today
            }
        }
    }

    // MARK: - 各行

    /// 二级页面入口：只有名字和箭头，右边不放多余的信息
    private func navRow(_ title: String, route: Route) -> some View {
        Button { router.open(route) } label: {
            SettingRow(title: title) { Chevron() }
        }
        .buttonStyle(PressableRowStyle())
    }

    /// 你（照设计稿）：头像（点一下从相册换，长按可以移除），右边是称呼，下面是 TA 们都知道的那段「你是谁」
    /// （宋体，存在世界观里，见 World.State.you）。两样都在这里直接改
    private var meRow: some View {
        HStack(alignment: .top, spacing: Space.page) {
            PhotosPicker(selection: $avatarItem, matching: .images) {
                UserAvatar(size: AvatarSize.me)
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel("更换我的头像")
            .contextMenu {
                if ImageFileStore.myAvatar.image != nil {
                    Button(role: .destructive) { withAnimation(Motion.spring) { ImageFileStore.myAvatar.clear() } } label: {
                        Label("移除头像", systemImage: "trash")
                    }
                }
            }
            .id(avatarStamp)
            VStack(alignment: .leading, spacing: Space.tiny) {
                TextField("怎么称呼你", text: $nickname)
                    .font(.system(size: Typo.title))
                    .tracking(Typo.tracking)
                    .foregroundStyle(Palette.ink)
                TextField("你是谁：住在哪、做什么、喜欢什么…", text: $you, axis: .vertical)
                    .font(Typo.serif(Typo.label))
                    .lineSpacing(Space.tiny)
                    .lineLimit(1...8)
                    .foregroundStyle(Palette.ink2)
                    .onChange(of: you) { _, new in
                        var s = World.state
                        guard s.you != new else { return }
                        s.you = new
                        World.state = s
                    }
                    .onReceive(NotificationCenter.default.publisher(for: World.changed)) { _ in
                        // 从备份恢复、恢复出厂设置后跟着变
                        let latest = World.state.you
                        if latest != you { you = latest }
                    }
            }
            .padding(.top, Space.tiny)
        }
        .padding(.horizontal, Space.card)
        .padding(.top, Space.page)
    }

    private var relayLine: String {
        switch relay.state {
        case .connected: relay.status.map { "已连接 · \($0.host)" } ?? "已连接"
        case .connecting: "连接中…"
        case .notConfigured: "未设置"
        case .failed(let reason): reason
        }
    }

    /// 电脑中继一行（照设计稿）：右边一个小绿点（连上了）和现在的状态，不放图标
    private func connectionRow(title: String, subtitle: String, ok: Bool) -> some View {
        SettingRow(title: title) {
            HStack(spacing: Space.tight) {
                StatusDot(ok: ok)
                Text(verbatim: subtitle).lineLimit(1)
            }
            .font(.system(size: Typo.value))
            .foregroundStyle(Palette.inkSoft)
            Chevron()
        }
    }

    /// Claude / Codex 一行：「Claude 默认模型」，右边是现在选的模型，点进去选模型和推理强度
    private func engineRow(_ engine: Engine) -> some View {
        let s = engine == .claude ? relay.status?.claude : relay.status?.codex
        let model = engine == .claude ? claudeModel : codexModel
        let effort = engine == .claude ? claudeEffort : codexEffort
        let value: String = s?.installed == false
            ? String(localized: "电脑上还没有安装")
            : ModelNames.summary(model, effort, engine: engine, status: relay.status)
        return Button { modelEngine = engine } label: {
            SettingRow(title: String(localized: "\(engine.label) 默认模型")) {
                Text(verbatim: value).font(.system(size: Typo.value)).foregroundStyle(Palette.inkSoft).lineLimit(1)
                Chevron()
            }
        }
        .buttonStyle(PressableRowStyle())
    }

    /// 模型 ID 的简写（中继还没报来模型清单时用，见 ModelNames.name）
    static func short(_ model: String) -> String {
        let map = ["claude-opus-5-5": "Opus 5.5", "claude-sonnet-5-5": "Sonnet 5.5", "claude-haiku-5-5": "Haiku 5.5",
                   "claude-fable-5-1": "Fable 5.1", "opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku"]
        return map[model] ?? model
    }
}

// MARK: - 状态点

/// 一个小圆点：绿 = 正常（连上了、装好了），灰 = 没连上（设置首页和电脑中继页共用）
struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle()
            .fill(ok ? Palette.online : Palette.faint)
            .frame(width: 8, height: 8)
            .accessibilityLabel(ok ? "正常" : "未连接")
    }
}
