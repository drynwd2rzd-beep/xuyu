import SwiftUI
import SwiftData

enum AppTab: Hashable { case home, chats, todo }

enum Route: Hashable {
    case chat(UUID)
    case settings
    case connection
    case personas
    case persona(UUID)
    case notifications
    case appearance
    case backup
    case privacy
}

@Observable
final class Router {
    var tab: AppTab = .home
    var path = NavigationPath()
    /// 当前打开的对话（用来决定要不要弹 App 内提示）
    var openConversation: UUID?
    /// 主页正在编辑小组件
    var homeEditing = false
    @ObservationIgnored var demoApplied = false

    func open(_ route: Route) { path.append(route) }
}

/// App 内的顶部消息提示
@MainActor
@Observable
final class BannerCenter {
    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let conversationID: UUID
        let title: String
        let body: String
        let tint: Int
        let initial: String
    }

    var current: Banner?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func show(_ banner: Banner) {
        guard UserDefaults.standard.object(forKey: Prefs.inAppBanner) as? Bool ?? true else { return }
        withAnimation(Motion.spring) { current = banner }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.spring) { self?.current = nil }
        }
    }

    func dismiss() {
        withAnimation(Motion.spring) { current = nil }
    }
}

/// CI 截图：`-demo YES -demoScreen chat` 用内存数据启动并直达指定页面
enum DemoMode {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: Prefs.demo) }
    static var screen: String { UserDefaults.standard.string(forKey: Prefs.demoScreen) ?? "" }

    @MainActor
    static func apply(router: Router, context: ModelContext) {
        guard isOn, !router.demoApplied else { return }
        router.demoApplied = true
        switch screen {
        case "chats": router.tab = .chats
        case "todo", "calendar": router.tab = .todo
        case "settings":
            router.tab = .todo
            router.open(.settings)
        case "backup":
            router.tab = .todo
            router.open(.settings)
            router.open(.backup)
        case "chat", "group", "stickers":
            router.tab = .chats
            let all = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
            let matching = all.filter { $0.isGroup == (screen == "group") }
            if let c = matching.max(by: { ($0.messages?.count ?? 0) < ($1.messages?.count ?? 0) }) { router.open(.chat(c.id)) }
        case "persona":
            router.tab = .chats
            if let p = context.allPersonas().first { router.open(.persona(p.id)) }
        default: break
        }
    }
}
