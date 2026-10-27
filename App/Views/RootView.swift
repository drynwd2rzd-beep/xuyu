import SwiftUI
import SwiftData
import UIKit

struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(BannerCenter.self) private var banners
    @State private var keyboardShown = false

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(Motion.snappy) { keyboardShown = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(Motion.snappy) { keyboardShown = false }
        }
    }

    /// 三个页面常驻，切换时保留滚动位置
    private func tabPage<Content: View>(_ tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        let active = router.tab == tab
        // 切换时旧页轻轻退后、新页缓缓浮现
        return content()
            .opacity(active ? 1 : 0)
            .scaleEffect(active ? 1 : 0.985)
            .offset(y: active ? 0 : 8)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
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
                        .font(Typo.serif(15.5, selected ? .semibold : .regular))
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
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.09), radius: 18, y: 8)
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
                    Text(banner.title).font(Typo.serif(13.5)).foregroundStyle(Palette.onNoir.opacity(0.7))
                    Text(banner.body).font(.system(size: 14.5)).foregroundStyle(Palette.onNoir).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.item)
            .padding(.vertical, 10)
            .background(Palette.noir, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
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
        case .chat(let id):
            if let convo = context.conversation(id) { ChatView(convo: convo) } else { missing }
        case .settings:
            SettingsView()
        case .connection:
            ConnectionView()
        case .personas:
            PersonasView()
        case .persona(let id):
            if let persona = context.persona(id) { PersonaEditor(persona: persona) } else { missing }
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
            Text(title).font(Typo.serif(18, .medium)).foregroundStyle(Palette.ink)
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
        .padding(.bottom, Space.tight)
        .background { HeaderFade(fade: 20) }
    }
}

extension SubpageHeader where Trailing == Color {
    init(title: String) {
        self.title = title
        self.trailing = Color.clear
    }
}
