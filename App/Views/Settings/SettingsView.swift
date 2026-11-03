import SwiftUI
import SwiftData
import PhotosUI

// MARK: - 设置首页

/// 设置首页：我（头像、称呼、你是谁）、AI（角色与群聊、世界、两个引擎的默认模型）、
/// App（电脑中继、语音服务、通知、外观、隐私、备份）、重置。每个角色自己的设置在编辑角色的五章里
struct SettingsView: View {
    @Environment(RelayClient.self) private var relay
    @Environment(Router.self) private var router
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
                .padding(.horizontal, Space.page)
                .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { SubpageHeader(title: "设置") }
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
        VStack(alignment: .leading, spacing: Space.section) {
            section("我") {
                meRow
                Hairline()
                youRow
            }

            section("AI") {
                Button { router.open(.personas) } label: {
                    SettingRow(title: "角色与群聊") {
                        Text("\(personas.count) 位").font(.system(size: 14)).foregroundStyle(Palette.inkSoft)
                        Chevron()
                    }
                }
                .buttonStyle(PressableRowStyle())
                Hairline()
                // 大家共用的世界：生活的世界、天气、关系
                navRow("世界", route: .world)
                Hairline()
                engineRow(.claude)
                Hairline(inset: 62)
                engineRow(.codex)
            }

            section("App") {
                Button { router.open(.connection) } label: {
                    connectionRow(title: "电脑中继", subtitle: relayLine, ok: relay.isConnected, symbol: "desktopcomputer")
                }
                .buttonStyle(PressableRowStyle())
                Hairline()
                navRow("语音服务", route: .voice)
                Hairline()
                navRow("通知", route: .notifications)
                Hairline()
                navRow("外观与背景", route: .appearance)
                Hairline()
                navRow("隐私与安全", route: .privacy)
                Hairline()
                navRow("备份与恢复", route: .backup)
            }

            // 从轻到重：只还原偏好 → 删掉所有角色 → 什么都删（像刚装好）
            section("重置") {
                resetRow("还原所有设置") { confirming = .settings }
                Hairline()
                resetRow("删除所有人设") { confirming = .personas }
                Hairline()
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

    /// 自己：头像（点一下从相册换，长按可恢复成文字头像）+ 称呼
    private var meRow: some View {
        HStack(spacing: Space.item) {
            PhotosPicker(selection: $avatarItem, matching: .images) {
                UserAvatar(size: 40)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Palette.inkInverse)
                            .frame(width: 17, height: 17)
                            .background(Palette.ink, in: Circle())
                            .overlay(Circle().strokeBorder(Palette.card, lineWidth: 1.5))
                            .offset(x: 3, y: 3)
                    }
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
            Text("我").font(.system(size: 16)).foregroundStyle(Palette.ink)
            Spacer()
            TextField("怎么称呼你", text: $nickname)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 15))
                .foregroundStyle(Palette.ink2)
                .frame(maxWidth: 160)
        }
        .padding(.horizontal, Space.card)
        .frame(height: Space.rowTall)
    }

    /// 你是谁：TA 们都知道的那一段（存在世界观里，见 World.State.you）
    private var youRow: some View {
        TextField("你是谁：住在哪、做什么、喜欢什么…", text: $you, axis: .vertical)
            .font(.system(size: 15))
            .lineSpacing(4)
            .lineLimit(2...8)
            .padding(Space.card)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var relayLine: String {
        switch relay.state {
        case .connected: relay.status.map { "已连接 · \($0.host)" } ?? "已连接"
        case .connecting: "连接中…"
        case .notConfigured: "未设置"
        case .failed(let reason): reason
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            SectionLabel(text: title)
            VStack(spacing: 0) { content() }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .card()
        }
    }

    private func connectionRow(title: String, subtitle: String, ok: Bool, symbol: String) -> some View {
        HStack(spacing: Space.item) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Palette.ink)
                .frame(width: 34, height: 34)
                .background(Palette.fill, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16)).foregroundStyle(Palette.ink)
                Text(subtitle).font(.system(size: Typo.secondary)).foregroundStyle(Palette.inkSoft).lineLimit(1)
            }
            Spacer()
            StatusDot(ok: ok)
            Chevron()
        }
        .padding(.horizontal, Space.card)
        .frame(height: Space.rowTall)
        .contentShape(Rectangle())
    }

    /// Claude / Codex 一行：显示它的默认模型，点进去选模型和推理强度
    private func engineRow(_ engine: Engine) -> some View {
        let s = engine == .claude ? relay.status?.claude : relay.status?.codex
        let model = engine == .claude ? claudeModel : codexModel
        let effort = engine == .claude ? claudeEffort : codexEffort
        let subtitle: String = if s?.installed == false {
            "电脑上还没有安装"
        } else {
            "默认模型 · " + ModelNames.summary(model, effort, engine: engine, status: relay.status)
        }
        return Button { modelEngine = engine } label: {
            HStack(spacing: Space.item) {
                EngineLogo(engine: engine, size: 18)
                    .frame(width: 34, height: 34)
                    .background(Palette.fill, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.label).font(.system(size: 16)).foregroundStyle(Palette.ink)
                    Text(subtitle).font(.system(size: Typo.secondary)).foregroundStyle(Palette.inkSoft).lineLimit(1)
                }
                Spacer()
                StatusDot(ok: s?.installed == true && relay.isConnected)
                Chevron()
            }
            .padding(.horizontal, Space.card)
            .frame(height: Space.rowTall)
            .contentShape(Rectangle())
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
            .fill(ok ? Color(hex: 0x5E8F58) : Palette.faint)
            .frame(width: 8, height: 8)
            .accessibilityLabel(ok ? "正常" : "未连接")
    }
}
