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
    @State private var lock = AppLock.shared
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
        UserDefaults.standard.set(backup.path, forKey: Prefs.lastStoreRescue)
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
                .overlay { if lock.locked { LockScreen(lock: lock) } }
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                .onAppear {
                    engine.attach(relay: relay, banners: banners, router: router)
                    AppDelegate.router = router
                    DemoMode.apply(router: router, context: container.mainContext, engine: engine)
                    // 聊天背景照片的模糊在后台先算好，第一次进聊天不卡
                    let convos = (try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? []
                    WallpaperStore.prewarm([nil] + convos.map { Optional($0.id) })
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
                lock.lockIfNeeded()
                // 离开 App 时：把「没回消息会来追问」提前准备好，App 关掉了也能按时收到
                let task = UIApplication.shared.beginBackgroundTask(withName: "followUps")
                Task {
                    await Companion.followUps(context: container.mainContext, relay: relay, personas: container.mainContext.allPersonas())
                    UIApplication.shared.endBackgroundTask(task)
                }
            }
            if phase == .active {
                Task { await lock.unlock() }
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
