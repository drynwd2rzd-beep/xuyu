import SwiftUI
import SwiftData
import UserNotifications

@main
struct XuyuApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Prefs.appearance) private var appearance = 0
    @State private var relay = RelayClient()
    @State private var engine = ChatEngine()
    @State private var router = Router()
    @State private var banners = BannerCenter()
    private let container: ModelContainer

    init() {
        container = Self.openStore()
        Seeder.prepare(container.mainContext)
    }

    /// 打开数据库。万一升级旧数据失败：先把旧数据库整份挪进「数据库备份」文件夹，再用新库启动，App 不会打不开
    private static func openStore() -> ModelContainer {
        let schema = Schema(Schema1.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: DemoMode.isOn)
        if let container = try? ModelContainer(for: schema, configurations: [config]) { return container }
        let store = config.url
        let dir = store.deletingLastPathComponent()
        let backup = dir.appendingPathComponent("数据库备份-\(Int(Date.now.timeIntervalSince1970))", isDirectory: true)
        try? FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        for suffix in ["", "-shm", "-wal"] {
            let file = URL(fileURLWithPath: store.path + suffix)
            try? FileManager.default.moveItem(at: file, to: backup.appendingPathComponent(file.lastPathComponent))
        }
        UserDefaults.standard.set(backup.path, forKey: "lastStoreRescue")
        if let container = try? ModelContainer(for: schema, configurations: [config]) { return container }
        // 实在不行就先用内存里的临时库，至少能打开
        return try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(relay)
                .environment(engine)
                .environment(router)
                .environment(banners)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                .onAppear {
                    engine.attach(relay: relay, banners: banners, router: router)
                    AppDelegate.router = router
                    DemoMode.apply(router: router, context: container.mainContext)
                    if !DemoMode.isOn {
                        relay.connectIfConfigured()
                        Task { await engine.recover(context: container.mainContext) }
                    }
                }
                .task {
                    // App 一直开着时，每 10 分钟看看有没有该做的事（比如过了 8 点该写日记了）
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(600))
                        guard !DemoMode.isOn, scenePhase == .active else { continue }
                        await Companion.refresh(context: container.mainContext, relay: relay)
                    }
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            guard !DemoMode.isOn else { return }
            if phase == .background {
                // 离开 App 时：把「没回消息会来追问」提前准备好，App 关掉了也能按时收到
                let task = UIApplication.shared.beginBackgroundTask(withName: "followUps")
                Task {
                    await Companion.followUps(context: container.mainContext, relay: relay, personas: container.mainContext.allPersonas())
                    UIApplication.shared.endBackgroundTask(task)
                }
            }
            if phase == .active {
                relay.wake()
                Task { await engine.recover(context: container.mainContext) }
                Task { await Companion.refresh(context: container.mainContext, relay: relay) }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var router: Router?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // 正开着这个聊天：消息直接出现在聊天里，不再弹通知
        let target = notification.request.content.userInfo["conversation"] as? String
        let open = await MainActor.run { AppDelegate.router?.openConversation?.uuidString }
        if let target, target == open { return [] }
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let target = info["conversation"] as? String
        let tab = info["tab"] as? String
        await MainActor.run {
            guard let router = AppDelegate.router else { return }
            if let target, let id = UUID(uuidString: target) {
                router.tab = .chats
                router.path = NavigationPath()
                router.open(.chat(id))
            } else if tab == "todo" {
                router.path = NavigationPath()
                router.tab = .todo
            }
        }
    }
}

enum Prefs {
    static let appearance = "appearance"
    static let nickname = "nickname"
    static let defaultClaudeModel = "defaultClaudeModel"
    static let defaultCodexModel = "defaultCodexModel"
    static let showReasoning = "showReasoning"
    static let showEngineLogo = "showEngineLogo"
    /// 谁来写 AI 日记（角色 ID）
    static let diaryWriter = "diaryWriter"
    /// 待办页是否显示「我」的日记
    static let showMyDiary = "showMyDiary"
    static let inAppBanner = "inAppBanner"
    static let todoReminders = "todoReminders"
    static let diaryReminder = "diaryReminder"
    static let quietStart = "quietStart"
    static let quietEnd = "quietEnd"
    static let wallpaper = "wallpaper"
    static let homeWidgets = "homeWidgets"
    static let relayAddress = "relayAddress"
    static let whisperDay = "whisperDay"
    static let whisperText = "whisperText"
    static let whisperAuthor = "whisperAuthor"

    static var nicknameValue: String { (UserDefaults.standard.string(forKey: nickname) ?? "").trimmed }

    static let defaultClaudeEffort = "defaultClaudeEffort"
    static let defaultCodexEffort = "defaultCodexEffort"

    static func defaultModel(for engine: Engine) -> String {
        UserDefaults.standard.string(forKey: engine == .claude ? defaultClaudeModel : defaultCodexModel) ?? ""
    }

    static func defaultEffort(for engine: Engine) -> String {
        UserDefaults.standard.string(forKey: engine == .claude ? defaultClaudeEffort : defaultCodexEffort) ?? ""
    }

    /// 免打扰时段（小时），默认 23:00–8:00
    static var quietHours: (Int, Int) {
        let d = UserDefaults.standard
        let s = d.object(forKey: quietStart) as? Int ?? 23
        let e = d.object(forKey: quietEnd) as? Int ?? 8
        return (s, e)
    }

    static func isQuiet(_ date: Date) -> Bool {
        let (s, e) = quietHours
        let h = Calendar.current.component(.hour, from: date)
        return s > e ? (h >= s || h < e) : (h >= s && h < e)
    }
}

enum Appearance: Int, CaseIterable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

enum Seeder {
    @MainActor
    static func prepare(_ context: ModelContext) {
        if DemoMode.isOn {
            DemoData.populate(context)
            return
        }
        let streaming = (try? context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.statusRaw == "streaming" }))) ?? []
        for m in streaming {
            // 有回复编号的先留着，连上电脑后去取回完整内容（ChatEngine.recover）
            if !m.relayID.isEmpty { continue }
            if m.content.isEmpty {
                m.status = .error
                m.errorText = "回复被中断"
            } else {
                m.status = .done
            }
        }
        if ((try? context.fetchCount(FetchDescriptor<Persona>())) ?? 0) == 0 {
            let claude = Persona(name: "Claude", engine: .claude, tint: 0x1E1E1F, bio: "温柔聪明的伙伴",
                                 systemPrompt: "你是 Claude，用户的私人伙伴。说话自然、温柔、简洁，像朋友聊天；需要时用 Markdown 组织内容；不确定的事情坦诚说明。")
            let codex = Persona(name: "Codex", engine: .codex, tint: 0xE7E3DA, bio: "擅长代码和动手",
                                systemPrompt: "你是 Codex，用户的技术伙伴。回答务实、清楚，给出可以直接执行的步骤。")
            codex.sortIndex = 1
            context.insert(claude)
            context.insert(codex)
            _ = context.chat(for: claude)
            _ = context.chat(for: codex)
        }
        try? context.save()
    }
}
