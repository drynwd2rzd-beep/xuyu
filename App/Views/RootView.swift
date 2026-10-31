import SwiftUI
import SwiftData
import UIKit

struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(BannerCenter.self) private var banners
    @State private var keyboardShown = false
    @State private var shownTab: AppTab = .today
    /// 上次打开时数据库升级失败、旧数据被挪进了「数据库备份」文件夹（见 XuyuApp.openStore）：告诉你一声
    @AppStorage(Prefs.lastStoreRescue) private var storeRescue = ""

    var body: some View {
        ZStack {
            // 列表淡开时，后面露出的是纸色，不是黑的
            Palette.paper.ignoresSafeArea()
            pages
                // 聊天开着时朝你放大、淡开；侧滑返回时跟着手指一点点回来
                .recede(router.chat == nil ? 0 : 1 - router.chatSwipe)
            // 进场动画途中，聊天层只画在安全区里（系统的限制），状态栏和底部横条那两截要靠这张整屏的聊天背景补上。
            // 它必须在列表上面：以前放在最底下，列表淡开要 0.3 秒，这段时间两截露出的是半透明的列表（真机录屏 17:15）。
            // 不跟着放大，只淡入淡出；开始侧滑时就淡掉，露出后面的列表
            if let id = router.chat {
                ChatBackdrop(id: id)
                    .ignoresSafeArea()
                    .opacity(Double(max(0, 1 - router.chatSwipe * 6)))
                    .id(id)
                    .transition(.opacity)
                    .zIndex(0.5)
            }
            if let id = router.chat {
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
        // 以前这里什么也不说：聊天全不见了，你也不知道数据其实还在
        .alert("原来的数据没能打开", isPresented: Binding(get: { !storeRescue.isEmpty }, set: { if !$0 { storeRescue = "" } })) {
            Button("从电脑恢复") {
                storeRescue = ""
                router.tab = .today
                router.path = NavigationPath()
                router.open(.settings)
                router.open(.backup)
            }
            Button("知道了", role: .cancel) { storeRescue = "" }
        } message: {
            Text("升级数据时出了问题，原来的数据已经原样留在手机里，没有删掉。可以从电脑上的备份恢复。")
        }
        .onChange(of: router.chat) { _, open in
            if open == nil { settleKeyboard() }
        }
    }

    /// 从聊天等页面回来时，确认键盘状态是真实的（避免底栏一直藏着）
    private func settleKeyboard() {
        Task {
            try? await Task.sleep(for: Motion.dismissSettle)
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
                tabPage(.today) { HomeView() }
                tabPage(.chats) { ChatListView() }
                tabPage(.moments) { MomentsView(root: true) }
            }
            // 上下边缘：往上滚的内容在状态栏那一截柔和地淡进纸色，不会硬生生切在时间下面；
            // 底栏后面也是一层由浓到淡的纸色，一直铺到屏幕最底下，底栏像浮在纸上。
            // safeAreaInsets.bottom 已经算上了底栏的高度（这一层在底栏的 safeAreaInset 里面）
            .overlay {
                GeometryReader { g in
                    VStack(spacing: 0) {
                        EdgeFade(edge: .top).frame(height: g.safeAreaInsets.top + 6)
                        Spacer(minLength: 0)
                        EdgeFade(edge: .bottom)
                            .frame(height: g.safeAreaInsets.bottom + 28)
                            .opacity(tabBarShown ? 1 : 0)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if tabBarShown {
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

    private var tabBarShown: Bool { !keyboardShown && !router.hideTabBar }

    private static let tabOrder: [AppTab] = [.today, .chats, .moments]

    /// 三个页面常驻，切换时保留滚动位置
    /// 切页：两页同时交叉淡入淡出——旧页往反方向轻轻滑走，新页从点的那一边滑进来，中间不会有空白。
    /// 以前是旧页先完全淡掉、隔 0.18 秒新页才出来，真机录屏里每次都有一两帧整屏黑的空白（页面越重越久）
    private func tabPage<Content: View>(_ tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        let active = shownTab == tab
        let order = Self.tabOrder
        // 在当前页左边的页面停在左边一点，右边的停在右边一点
        let side: CGFloat = (order.firstIndex(of: tab) ?? 0) < (order.firstIndex(of: shownTab) ?? 0) ? -1 : 1
        // 减少动态效果：不滑、不缩，只淡入淡出
        let still = active || Motion.reduced
        return content()
            .opacity(active ? 1 : 0)
            .offset(x: still ? 0 : 24 * side)
            .scaleEffect(still ? 1 : 0.985)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }

    private func switchTab(to new: AppTab) {
        guard new != shownTab else { return }
        // 切页时先收起键盘，底栏不会因为键盘状态残留而消失
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(Motion.reduced ? Motion.fade : Motion.snappy) { shownTab = new }
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
    var hideTabBar: Bool { homeEditing && tab == .today }
}

struct FloatingTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var pill

    private struct Item: Identifiable {
        let tab: AppTab
        let title: String
        var id: AppTab { tab }
    }

    private let items = [Item(tab: .today, title: "Today"), Item(tab: .chats, title: "Chats"), Item(tab: .moments, title: "Moments")]

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
        case .world:
            WorldView()
        case .worldLife(let id):
            if let persona = context.persona(id) { PersonaLifeView(persona: persona) } else { missing }
        case .worldEvents:
            WorldEventsView()
        case .personaPage(let id, let page):
            if let persona = context.persona(id) { PersonaSubpage(persona: persona, page: page) } else { missing }
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
