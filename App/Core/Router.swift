import SwiftUI

/// 底部三页：Today（主页和待办合在一起）· Chats · Moments
enum AppTab: Hashable { case today, chats, moments }

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
    case voice
    /// 全部动态
    case moments
    /// 某个角色的主页和动态
    case momentsOf(UUID)
    /// 一条动态的详情：帖子和全部评论
    case moment(UUID, comment: Bool)
    /// 世界观：世界、世界大事和快到的日子（每个人自己的生活在编辑角色的「生活」一章里）
    case world
    case worldEvents
}

/// 导航状态：底部哪一页、页面栈、盖在最上面的聊天和侧滑返回的进度
@MainActor
@Observable
final class Router {
    var tab: AppTab = .today
    var path = NavigationPath()
    /// 打开着的聊天：盖在所有页面上面，像穿梭一样从点的那一行飞进去、返回时像雾一样散开（见 ChatLayer）
    private(set) var chat: UUID?
    /// 从哪儿飞进聊天：点的那一行在屏幕上的位置（从主页、通知进来时没有，就从屏幕中间）
    private(set) var chatOrigin: CGRect?
    /// 从聊天里再点进去的页面（角色设置等），在聊天这一层里推进
    var chatPath = NavigationPath()
    /// 侧滑返回聊天的进度 0～1：聊天页跟着手指往右走，底下的页面跟着回来。每次打开聊天都从 0 开始
    var chatSwipe: CGFloat = 0
    /// 当前打开的对话（用来决定要不要弹 App 内提示）
    var openConversation: UUID?
    @ObservationIgnored var demoApplied = false

    /// from：从哪一行点进来的（屏幕上的位置），聊天会从那里飞进去
    func open(_ route: Route, from origin: CGRect? = nil) {
        if case .chat(let id) = route {
            chatPath = NavigationPath()
            chatOrigin = origin
            // 先清零：刚侧滑关掉、还没完全消失的聊天页被重新打开时，不会还缩在那儿
            chatSwipe = 0
            withAnimation(Motion.shuttleIn) { chat = id }
        } else if chat != nil {
            chatPath.append(route)
        } else {
            path.append(route)
        }
    }

    func closeChat() {
        withAnimation(Motion.shuttleOut) { chat = nil }
    }

    /// 侧滑松手、决定返回：聊天页带着手指的速度继续往右滑出屏幕，滑出去以后再悄悄拿掉（不播散开的动画）。
    /// velocity：松手时每秒划过几个屏幕宽
    func swipeAway(velocity: CGFloat) {
        guard let id = chat else { return }
        let left = max(0.05, 1 - chatSwipe)
        // 短而不弹的一段：以前那条弹簧收尾太慢，聊天页滑到右边还剩一条窄边停在那儿，过一会儿才突然消失（真机录屏）
        withAnimation(.interpolatingSpring(duration: 0.3, bounce: 0, initialVelocity: max(0, velocity) / left)) {
            chatSwipe = 1
        } completion: { [weak self] in
            // 滑出去的这段时间里又打开了聊天：不要把新打开的关掉
            guard let self, self.chat == id, self.chatSwipe == 1 else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                self.chat = nil
                self.chatSwipe = 0
            }
        }
    }

    /// 侧滑松手、不返回：带着手指的速度弹回原位
    func swipeBack(velocity: CGFloat) {
        let left = max(0.05, chatSwipe)
        withAnimation(.interpolatingSpring(duration: 0.34, bounce: 0, initialVelocity: max(0, -velocity) / left)) {
            chatSwipe = 0
        }
    }
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
