import SwiftUI
import SwiftData

/// 二级设置页通用的分组卡片
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            SectionLabel(text: title)
            VStack(spacing: 0) { content }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .card()
        }
    }
}

/// 二级设置页的外框：标题、滚动、纸色背景
struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) { content }
                .padding(.horizontal, Space.page)
                .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { SubpageHeader(title: title) }
        .background(Palette.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - 隐私与安全

struct PrivacySettingsView: View {
    @AppStorage(Prefs.appLock) private var appLock = false
    @AppStorage(Prefs.workAuth) private var workAuth = false

    var body: some View {
        SettingsPage(title: "隐私与安全") {
            SettingsGroup(title: "Face ID") {
                SettingRow(title: "打开 App") { InkToggle(isOn: guarded($appLock), label: "打开 App 需要 Face ID") }
                Hairline()
                SettingRow(title: "让 TA 操作电脑") { InkToggle(isOn: guarded($workAuth), label: "让 TA 操作电脑前需要 Face ID") }
            }
        }
    }

    /// 打开、关掉都要先确认是你本人，别人拿到手机也改不了
    private func guarded(_ value: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue }, set: { new in
            Task {
                if await AppLock.authenticate(new ? "开启 Face ID 保护" : "关闭 Face ID 保护") {
                    withAnimation(Motion.spring) { value.wrappedValue = new }
                }
            }
        })
    }
}

// MARK: - 通知

struct NotificationSettingsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(Prefs.inAppBanner) private var inAppBanner = true
    @AppStorage(Prefs.todoReminders) private var todoReminders = true
    @AppStorage(Prefs.diaryReminder) private var diaryReminder = true
    @AppStorage(Prefs.quietStart) private var quietStart = 23
    @AppStorage(Prefs.quietEnd) private var quietEnd = 8
    @State private var showQuiet = false

    var body: some View {
        SettingsPage(title: "通知") {
            SettingsGroup(title: "提醒") {
                SettingRow(title: "App 内消息提示", subtitle: "在别的页面时，回复会从顶部滑下") {
                    InkToggle(isOn: $inAppBanner, label: "App 内消息提示")
                }
                Hairline()
                SettingRow(title: "待办提醒") { InkToggle(isOn: $todoReminders, label: "待办提醒") }
                Hairline()
                SettingRow(title: "日记提醒", subtitle: "每晚 22:00") { InkToggle(isOn: $diaryReminder, label: "日记提醒") }
            }
            SettingsGroup(title: "安静") {
                Button { showQuiet = true } label: {
                    SettingRow(title: "免打扰", subtitle: "这段时间里不会主动找你，回复也静音") {
                        Text(String(format: "%02d:00 – %02d:00", quietStart, quietEnd)).font(.system(size: 14)).foregroundStyle(Palette.inkSoft)
                        Chevron()
                    }
                }
                .buttonStyle(PressableRowStyle())
            }
        }
        .sheet(isPresented: $showQuiet) {
            QuietHoursSheet(start: $quietStart, end: $quietEnd)
                .presentationDetents([.height(320)])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        .onChange(of: todoReminders) { _, _ in
            let all = (try? context.fetch(FetchDescriptor<TodoItem>())) ?? []
            all.forEach(Reminders.sync)
        }
        .onChange(of: diaryReminder) { _, on in
            Reminders.syncDiaryReminder()
            if on { Task { _ = await Reminders.ensureAuthorized() } }
        }
    }
}

// MARK: - 外观与背景

struct AppearanceSettingsView: View {
    @AppStorage(Prefs.appearance) private var appearance = 0
    @AppStorage(Prefs.showEngineLogo) private var showEngineLogo = true

    var body: some View {
        SettingsPage(title: "外观与背景") {
            SettingsGroup(title: "颜色") {
                Segmented(items: Appearance.allCases.map { ($0.rawValue, $0.label) }, selection: $appearance)
                    .padding(Space.card)
            }
            SettingsGroup(title: "聊天背景") {
                VStack(alignment: .leading, spacing: Space.tight) {
                    WallpaperPicker(owner: nil)
                    Text("每个聊天也可以单独换背景：在角色页或群聊信息里设置。")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.inkSoft)
                }
                .padding(Space.card)
            }
            SettingsGroup(title: "消息") {
                SettingRow(title: "名字旁显示模型图标") { InkToggle(isOn: $showEngineLogo, label: "名字旁显示模型图标") }
            }
        }
    }
}

// MARK: - 备份与恢复

struct BackupView: View {
    @Environment(\.modelContext) private var context
    @Environment(RelayClient.self) private var relay
    @AppStorage(Backup.autoKey) private var auto = true
    @AppStorage(Backup.lastBackupKey) private var lastBackup = 0.0
    @State private var working: String?
    @State private var toast: String?
    @State private var pcBackups: [RelayClient.BackupInfo] = []
    @State private var restoring: RestoreSource?
    @State private var exportDoc: BackupDocument?
    @State private var showImporter = false

    enum RestoreSource: Identifiable {
        case pc(String)
        case file(Data)
        var id: String {
            switch self {
            case .pc(let name): name
            case .file: "file"
            }
        }
    }

    var body: some View {
        SettingsPage(title: "备份与恢复") {
            SettingsGroup(title: "备份到电脑") {
                SettingRow(title: "每天自动备份", subtitle: "连着电脑时每天一次，存在电脑的 D:\\絮语备份，保留最近 30 份") {
                    InkToggle(isOn: $auto, label: "每天自动备份")
                }
                Hairline()
                actionRow("立即备份到电脑", detail: lastBackup > 0 ? "上次 " + Date(timeIntervalSince1970: lastBackup).listStamp : "",
                          disabled: !relay.isConnected) {
                    run("正在备份…") {
                        let ok = await Backup.backupToPC(context: context, relay: relay)
                        return ok ? "已备份到电脑" : "备份失败，请确认电脑连着"
                    }
                }
            }

            SettingsGroup(title: "从电脑恢复") {
                if !relay.isConnected {
                    Text("连上电脑后显示电脑上的备份").font(.system(size: 14)).foregroundStyle(Palette.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Space.card)
                } else if pcBackups.isEmpty {
                    Text("电脑上还没有备份").font(.system(size: 14)).foregroundStyle(Palette.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Space.card)
                } else {
                    ForEach(pcBackups.prefix(8)) { b in
                        Button { restoring = .pc(b.name) } label: {
                            SettingRow(title: b.at.listStamp + " " + Fmt.hm.string(from: b.at),
                                       subtitle: ByteCountFormatter.string(fromByteCount: Int64(b.size), countStyle: .file)) {
                                Text("恢复").font(.system(size: 14)).foregroundStyle(Palette.ink2)
                            }
                        }
                        .buttonStyle(PressableRowStyle())
                        if b.id != pcBackups.prefix(8).last?.id { Hairline() }
                    }
                }
            }

            SettingsGroup(title: "文件") {
                actionRow("导出到「文件」", detail: "", disabled: false) {
                    run("正在打包…") {
                        guard let data = try? Backup.export(context: context) else { return "导出失败" }
                        exportDoc = BackupDocument(data: data)
                        return nil
                    }
                }
                Hairline()
                actionRow("从文件恢复", detail: "", disabled: false) { showImporter = true }
            }

            Text("恢复会用备份里的内容替换现在 App 里的全部角色、聊天、待办和日记。")
                .font(.system(size: 12.5)).foregroundStyle(Palette.inkSoft).padding(.horizontal, 6)
        }
        .overlay(alignment: .top) {
            if let note = working ?? toast {
                Text(note)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.onNoir)
                    .padding(.horizontal, Space.card)
                    .frame(height: 36)
                    .background(Palette.noir, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.spring, value: working ?? toast)
        .task(id: relay.isConnected) { pcBackups = await relay.listBackups() }
        .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: .json, defaultFilename: Backup.fileName) { result in
            if case .success = result { flash("已导出") }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { restoring = .file(data) }
        }
        .confirmationDialog("用这份备份替换现在的内容？", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            titleVisibility: .visible, presenting: restoring) { source in
            Button("恢复", role: .destructive) { restore(source) }
        } message: { _ in
            Text("现在 App 里的角色、聊天、待办和日记会被备份里的内容替换。建议先备份一次现在的。")
        }
    }

    private func actionRow(_ title: String, detail: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SettingRow(title: title) {
                if !detail.isEmpty { Text(detail).font(.system(size: 13)).foregroundStyle(Palette.inkSoft) }
                Chevron()
            }
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(PressableRowStyle())
        .disabled(disabled || working != nil)
    }

    private func run(_ label: String, _ job: @escaping () async -> String?) {
        working = label
        Task {
            let result = await job()
            working = nil
            if let result { flash(result) }
        }
    }

    private func restore(_ source: RestoreSource) {
        run("正在恢复…") {
            let data: Data?
            switch source {
            case .pc(let name): data = await relay.fetchBackup(name)
            case .file(let d): data = d
            }
            guard let data else { return "取回备份失败" }
            do {
                try Backup.restore(data, context: context)
                return "已恢复"
            } catch {
                return "这个文件不是有效的絮语备份"
            }
        }
    }

    private func flash(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            toast = nil
        }
    }
}
