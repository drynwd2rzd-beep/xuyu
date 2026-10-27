import SwiftUI
import SwiftData
import PhotosUI

struct SettingsView: View {
    @Environment(RelayClient.self) private var relay
    @Environment(Router.self) private var router
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @AppStorage(Prefs.nickname) private var nickname = ""
    @AppStorage(Prefs.showReasoning) private var showReasoning = true
    @AppStorage(Prefs.inAppBanner) private var inAppBanner = true
    @AppStorage(Prefs.todoReminders) private var todoReminders = true
    @AppStorage(Prefs.diaryReminder) private var diaryReminder = true
    @AppStorage(Prefs.quietStart) private var quietStart = 23
    @AppStorage(Prefs.quietEnd) private var quietEnd = 8
    @AppStorage(Prefs.appearance) private var appearance = 0
    @AppStorage(Prefs.wallpaper) private var wallpaper = 0
    @AppStorage(Prefs.defaultClaudeModel) private var claudeModel = ""
    @AppStorage(Prefs.defaultCodexModel) private var codexModel = ""
    @State private var showModels = false
    @State private var showQuiet = false
    @State private var wallpaperItem: PhotosPickerItem?
    @State private var wallpaperVersion = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                section("连接") {
                    Button { router.open(.connection) } label: {
                        connectionRow(title: "电脑中继", subtitle: relayLine, ok: relay.isConnected, symbol: "desktopcomputer")
                    }
                    .buttonStyle(PressableRowStyle())
                    Hairline(inset: 62)
                    engineRow(.claude)
                    Hairline(inset: 62)
                    engineRow(.codex)
                }

                section("对话") {
                    Button { router.open(.personas) } label: {
                        SettingRow(title: "角色") {
                            Text("\(personas.count) 位").font(.system(size: 14)).foregroundStyle(Palette.inkSoft)
                            Chevron()
                        }
                    }
                    .buttonStyle(PressableRowStyle())
                    Hairline()
                    Button { showModels = true } label: {
                        SettingRow(title: "默认模型") {
                            Text(Self.short(claudeModel.isEmpty ? "自动" : claudeModel)).font(.system(size: 14)).foregroundStyle(Palette.inkSoft)
                            Chevron()
                        }
                    }
                    .buttonStyle(PressableRowStyle())
                    Hairline()
                    SettingRow(title: "你的称呼") {
                        TextField("怎么称呼你", text: $nickname)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.ink2)
                            .frame(maxWidth: 160)
                    }
                    Hairline()
                    SettingRow(title: "显示思考过程") { InkToggle(isOn: $showReasoning, label: "显示思考过程") }
                }

                section("通知") {
                    SettingRow(title: "App 内消息提示", subtitle: "在别的页面时，回复会从顶部滑下") {
                        InkToggle(isOn: $inAppBanner, label: "App 内消息提示")
                    }
                    Hairline()
                    SettingRow(title: "待办提醒") { InkToggle(isOn: $todoReminders, label: "待办提醒") }
                    Hairline()
                    SettingRow(title: "日记提醒", subtitle: "每晚 22:00") { InkToggle(isOn: $diaryReminder, label: "日记提醒") }
                    Hairline()
                    Button { showQuiet = true } label: {
                        SettingRow(title: "免打扰") {
                            Text(String(format: "%02d:00 – %02d:00", quietStart, quietEnd)).font(.system(size: 14)).foregroundStyle(Palette.inkSoft)
                            Chevron()
                        }
                    }
                    .buttonStyle(PressableRowStyle())
                }

                section("外观") {
                    VStack(alignment: .leading, spacing: Space.section) {
                        Segmented(items: Appearance.allCases.map { ($0.rawValue, $0.label) }, selection: $appearance)
                        Text("聊天背景").font(.system(size: 14)).foregroundStyle(Palette.ink)
                        HStack(spacing: 10) {
                            ForEach(0..<3, id: \.self) { i in
                                wallpaperSwatch(index: i, label: ChatWallpaper.swatches[i].0) {
                                    ChatWallpaper.swatches[i].1
                                }
                            }
                            PhotosPicker(selection: $wallpaperItem, matching: .images) {
                                swatchBody(index: 3, label: "自定义照片") {
                                    if wallpaper == 3, let image = WallpaperStore.image {
                                        Image(uiImage: image).resizable().scaledToFill().id(wallpaperVersion)
                                    } else {
                                        ZStack {
                                            Palette.paper
                                            Image(systemName: "photo").font(.system(size: 17)).foregroundStyle(Palette.inkSoft)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(Space.card)
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { SubpageHeader(title: "设置") }
        .background(Palette.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showModels) {
            ModelPicker(claude: $claudeModel, codex: $codexModel, status: relay.status)
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        .sheet(isPresented: $showQuiet) {
            QuietHoursSheet(start: $quietStart, end: $quietEnd)
                .presentationDetents([.height(320)])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        .onChange(of: wallpaperItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    WallpaperStore.save(data)
                    wallpaper = 3
                    wallpaperVersion += 1
                }
                wallpaperItem = nil
            }
        }
        .onChange(of: todoReminders) { _, _ in resyncTodos() }
        .onChange(of: diaryReminder) { _, on in
            Reminders.syncDiaryReminder()
            if on { Task { _ = await Reminders.ensureAuthorized() } }
        }
        .onAppear { relay.refreshStatus() }
    }

    @Environment(\.modelContext) private var context

    private func resyncTodos() {
        let all = (try? context.fetch(FetchDescriptor<TodoItem>())) ?? []
        all.forEach(Reminders.sync)
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
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Palette.inkSoft).lineLimit(1)
            }
            Spacer()
            StatusDot(ok: ok)
            Chevron()
        }
        .padding(.horizontal, Space.card)
        .frame(height: Space.rowTall)
        .contentShape(Rectangle())
    }

    private func engineRow(_ engine: Engine) -> some View {
        let s = engine == .claude ? relay.status?.claude : relay.status?.codex
        return HStack(spacing: Space.item) {
            EngineLogo(engine: engine, size: 18)
                .frame(width: 34, height: 34)
                .background(Palette.fill, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.label).font(.system(size: 16)).foregroundStyle(Palette.ink)
                Text(s.map { $0.installed ? "订阅账号 · \($0.version)" : "电脑上还没有安装" } ?? "连接电脑后显示")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.inkSoft).lineLimit(1)
            }
            Spacer()
            StatusDot(ok: s?.installed == true && relay.isConnected)
        }
        .padding(.horizontal, Space.card)
        .frame(height: Space.rowTall)
    }

    private func wallpaperSwatch<C: View>(index: Int, label: String, @ViewBuilder fill: () -> C) -> some View {
        Button { wallpaper = index } label: { swatchBody(index: index, label: label, fill: fill) }
            .buttonStyle(.plain)
    }

    private func swatchBody<C: View>(index: Int, label: String, @ViewBuilder fill: () -> C) -> some View {
        VStack(spacing: 6) {
            fill()
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(wallpaper == index ? Palette.ink : Palette.hairline, lineWidth: wallpaper == index ? 2 : 0.5))
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.inkSoft).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: wallpaper)
    }

    static func short(_ model: String) -> String {
        let map = ["claude-opus-5-5": "Opus 5.5", "claude-sonnet-5-5": "Sonnet 5.5", "claude-haiku-5-5": "Haiku 5.5",
                   "claude-fable-5-1": "Fable 5.1", "opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku"]
        return map[model] ?? model
    }
}

struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle()
            .fill(ok ? Color(hex: 0x5E8F58) : Palette.faint)
            .frame(width: 8, height: 8)
            .accessibilityLabel(ok ? "正常" : "未连接")
    }
}

/// 默认模型：Claude 和 Codex 各选一个
struct ModelPicker: View {
    @Binding var claude: String
    @Binding var codex: String
    let status: RelayStatus?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                HStack {
                    Text("默认模型").font(Typo.serif(20, .medium)).foregroundStyle(Palette.ink)
                    Spacer()
                    Button("完成") { dismiss() }.fontWeight(.semibold).foregroundStyle(Palette.ink)
                }
                group(.claude, models: status?.models.claude ?? ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"], selection: $claude)
                group(.codex, models: status?.models.codex ?? [], selection: $codex)
            }
            .padding(Space.page)
        }
    }

    private func group(_ engine: Engine, models: [String], selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack(spacing: 6) {
                EngineLogo(engine: engine, size: 14)
                Text(engine.label).font(Typo.serif(13.5)).foregroundStyle(Palette.inkSoft)
            }
            .padding(.leading, 6)
            VStack(spacing: 0) {
                row("自动（账号默认）", value: "", selection: selection)
                ForEach(models, id: \.self) { m in
                    Hairline()
                    row(SettingsView.short(m), value: m, selection: selection)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .card()
        }
    }

    private func row(_ title: String, value: String, selection: Binding<String>) -> some View {
        Button { selection.wrappedValue = value } label: {
            SettingRow(title: title) {
                if selection.wrappedValue == value {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                }
            }
        }
        .buttonStyle(PressableRowStyle())
        .sensoryFeedback(.selection, trigger: selection.wrappedValue)
    }
}

struct QuietHoursSheet: View {
    @Binding var start: Int
    @Binding var end: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            HStack {
                Text("免打扰").font(Typo.serif(20, .medium)).foregroundStyle(Palette.ink)
                Spacer()
                Button("完成") { dismiss() }.fontWeight(.semibold).foregroundStyle(Palette.ink)
            }
            HStack {
                picker("开始", $start)
                Text("–").foregroundStyle(Palette.inkSoft)
                picker("结束", $end)
            }
            .padding(Space.card)
            .card()
            Text("这段时间里，角色不会主动给你发消息。").font(.system(size: 13)).foregroundStyle(Palette.inkSoft).padding(.leading, 6)
        }
        .padding(Space.page)
    }

    private func picker(_ label: String, _ value: Binding<Int>) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
            Picker(label, selection: value) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(height: 110)
        }
        .frame(maxWidth: .infinity)
    }
}
