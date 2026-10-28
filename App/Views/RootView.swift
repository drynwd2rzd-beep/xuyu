import SwiftUI
import SwiftData
import UIKit

struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(BannerCenter.self) private var banners
    @State private var keyboardShown = false
    @State private var shownTab: AppTab = .home
    @State private var revealed = true
    @State private var direction: CGFloat = 1
    @State private var entering = false

    var body: some View {
        ZStack {
            // 列表淡开时，后面露出的是纸色，不是黑的
            Palette.paper.ignoresSafeArea()
            pages
                // 聊天开着时朝你放大、淡开；侧滑返回时跟着手指一点点回来
                .recede(router.chat == nil ? 0 : 1 - router.chatSwipe)
            if let id = router.chat {
                // 整屏的聊天背景：在聊天层外面、和它一起动，进场途中状态栏和底部横条那两截也有图（见 ChatLayer）
                ChatBackdrop(id: id)
                    .ignoresSafeArea()
                    .id(id)
                    .transition(.shuttle(from: router.chatOrigin, fullScreen: true))
                    .zIndex(0.5)
                ChatLayer(id: id)
                    .id(id)
                    .transition(.shuttle(from: router.chatOrigin))
                    .zIndex(1)
            }
        }
        // App 内的消息提示：盖在聊天上面，在别的聊天里也能看到
        .overlay(alignment: .top) {
            if let banner = banners.current {
                InAppBanner(banner: banner) {
                    banners.dismiss()
                    router.tab = .chats
                    router.path = NavigationPath()
                    router.open(.chat(banner.conversationID))
                }
                .padding(.horizontal, Space.page)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // 保存失败：盖在所有页面上面（包括聊天）
        .overlay(alignment: .top) { SaveAlertToast() }
        .onChange(of: router.chat) { _, open in
            if open == nil { settleKeyboard() }
        }
    }

    /// 从聊天等页面回来时，确认键盘状态是真实的（避免底栏一直藏着）
    private func settleKeyboard() {
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            let up = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first?.firstResponderIsTextInput ?? false
            if !up { withAnimation(Motion.snappy) { keyboardShown = false } }
        }
    }

    private var pages: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.path) {
            ZStack {
                Palette.paper.ignoresSafeArea()
                tabPage(.home) { HomeView() }
                tabPage(.chats) { ChatListView() }
                tabPage(.todo) { TodoView() }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !keyboardShown && !router.hideTabBar {
                    FloatingTabBar(selection: $router.tab)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
        .tint(Palette.ink)
        .onAppear { shownTab = router.tab }
        .onChange(of: router.path.count) { _, count in
            if count == 0 { settleKeyboard() }
        }
        .onChange(of: router.tab) { _, new in switchTab(to: new) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(Motion.snappy) { keyboardShown = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(Motion.snappy) { keyboardShown = false }
        }
    }

    /// 三个页面常驻，切换时保留滚动位置
    /// 切页：旧页朝反方向轻轻滑走、淡出；新页从点的方向滑进来、淡入（不做模糊，切页不掉帧）
    private func tabPage<Content: View>(_ tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        let active = shownTab == tab
        let visible = active && revealed
        // 减少动态效果：不滑、不缩，只淡入淡出
        let still = visible || Motion.reduced
        let shift: CGFloat = entering ? 28 * direction : -18 * direction
        return content()
            .opacity(visible ? 1 : 0)
            .offset(x: still ? 0 : shift)
            .scaleEffect(still ? 1 : 0.975)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }

    private func switchTab(to new: AppTab) {
        guard new != shownTab else { return }
        // 切页时先收起键盘，底栏不会因为键盘状态残留而消失
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let order: [AppTab] = [.home, .chats, .todo]
        direction = (order.firstIndex(of: new) ?? 0) > (order.firstIndex(of: shownTab) ?? 0) ? 1 : -1
        entering = false
        withAnimation(Motion.fade) { revealed = false }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            // 连续点得很快时，只显示最后点的那个
            guard router.tab == new else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                shownTab = new
                entering = true
            }
            withAnimation(Motion.spring) { revealed = true }
        }
    }
}

extension UIView {
    /// 当前是不是有输入框正在打字（键盘真的开着）
    var firstResponderIsTextInput: Bool {
        if isFirstResponder { return self is UITextInput }
        return subviews.contains { $0.firstResponderIsTextInput }
    }
}

extension Router {
    /// 主页编辑小组件时隐藏底栏
    var hideTabBar: Bool { homeEditing && tab == .home }
}

struct FloatingTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var pill

    private struct Item: Identifiable {
        let tab: AppTab
        let title: String
        var id: AppTab { tab }
    }

    private let items = [Item(tab: .home, title: "Home"), Item(tab: .chats, title: "Chats"), Item(tab: .todo, title: "To Do")]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let selected = selection == item.tab
                Button {
                    withAnimation(Motion.spring) { selection = item.tab }
                } label: {
                    Text(item.title)
                        .font(Typo.serif(Typo.body, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Palette.inkInverse : Palette.inkSoft)
                        .padding(.horizontal, 20)
                        .frame(height: 44)
                        .background {
                            if selected {
                                Capsule().fill(Palette.ink).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background {
            Capsule().fill(.ultraThinMaterial).shadow(color: .black.opacity(0.09), radius: 18, y: 8)
        }
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
        .padding(.bottom, 6)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

struct InAppBanner: View {
    let banner: BannerCenter.Banner
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Space.item) {
                InitialAvatar(text: banner.initial, tint: UInt32(truncatingIfNeeded: banner.tint), size: 34)
                    .frame(width: 34, height: 34)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(banner.title).font(Typo.serif(Typo.label)).foregroundStyle(Palette.onNoir.opacity(0.7))
                    Text(banner.body).font(.system(size: 14)).foregroundStyle(Palette.onNoir).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.item)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.noir)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
            }
        }
        .buttonStyle(ScaleButtonStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: banner.id)
    }
}

struct RouteView: View {
    let route: Route
    @Environment(\.modelContext) private var context

    var body: some View {
        switch route {
        case .chat:
            // 聊天不在这里推进，而是由 Router.open 打开在最上面的聊天层（ChatLayer）
            missing
        case .settings:
            SettingsView()
        case .connection:
            ConnectionView()
        case .personas:
            PersonasView()
        case .persona(let id):
            if let persona = context.persona(id) { PersonaEditor(persona: persona) } else { missing }
        case .notifications:
            NotificationSettingsView()
        case .appearance:
            AppearanceSettingsView()
        case .backup:
            BackupView()
        case .privacy:
            PrivacySettingsView()
        case .voice:
            VoiceSettingsView()
        case .moments:
            MomentsView()
        case .momentsOf(let id):
            if let persona = context.persona(id) { MomentProfileView(persona: persona) } else { missing }
        }
    }

    private var missing: some View {
        ContentUnavailableView("内容已删除", systemImage: "tray")
            .background(Palette.paper.ignoresSafeArea())
    }
}

/// 隐藏导航栏后保留系统的右滑返回手势
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

/// 自定义页头：返回 + 标题（用于设置等二级页面），顶部纸色渐变
struct SubpageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // 标题始终居中，左右按钮各占固定宽度
        ZStack {
            Text(LocalizedStringKey(title)).font(Typo.serif(18, .medium)).foregroundStyle(Palette.ink)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("返回")
                Spacer()
                trailing
                    .frame(width: 64, height: 44, alignment: .trailing)
                    .padding(.trailing, 6)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, Space.tight)
        // 渐变整段收在页头里面：没滚动时，第一个分区的标题不会被盖得发白；往上滚的内容照样在这里柔和地淡出
        .padding(.bottom, Self.fade)
        .background { HeaderFade(fade: Self.fade).padding(.bottom, Self.fade) }
    }

    private static var fade: CGFloat { 16 }
}

extension SubpageHeader where Trailing == Color {
    init(title: String) {
        self.title = title
        self.trailing = Color.clear
    }
}
