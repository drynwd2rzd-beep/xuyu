import SwiftUI
import SwiftData

/// CI 截图：`-demo YES -demoScreen chat` 用内存数据启动并直达指定页面
enum DemoMode {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: Prefs.demo) }
    static var screen: String { UserDefaults.standard.string(forKey: Prefs.demoScreen) ?? "" }

    @MainActor
    static func apply(router: Router, context: ModelContext, engine: ChatEngine) {
        guard isOn, !router.demoApplied else { return }
        router.demoApplied = true
        switch screen {
        case "chats": router.tab = .chats
        case "today", "past", "calendar": router.tab = .today
        case "settings":
            router.tab = .today
            router.open(.settings)
        case "backup":
            router.tab = .today
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
        case "moments":
            router.tab = .moments
        case "profile":
            router.tab = .moments
            if let p = context.allPersonas().first { router.open(.momentsOf(p.id)) }
        case "motion":
            router.tab = .chats
            DemoMotion.run(router: router, context: context, engine: engine)
        default: break
        }
    }
}
