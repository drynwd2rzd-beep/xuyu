import SwiftUI
import SwiftData

/// 聊天页：背景、页头、消息列表和底下的输入栏叠在一起。
/// 消息列表见 ChatMessageList，长按消息的动作见 ChatMessageActions，底部的多选条、输入栏和轻提示见 ChatBottomBar。
/// 消息列表不用懒加载是有意的：只排版最近 120 条，更早的点「查看更早的消息」再加载（DATA-8）。
/// 状态都留在这个视图里，拆出去的部分是同一个视图的扩展，刷新时机和原来一样
struct ChatView: View {
    @Bindable var convo: Conversation
    @Environment(\.modelContext) var context
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatEngine.self) var engine
    @Environment(RelayClient.self) private var relay
    @Environment(Router.self) private var router
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @Environment(\.colorScheme) private var systemScheme
    @AppStorage(Prefs.wallpaper) private var globalWallpaper = 0
    @AppStorage(WallpaperStore.stampKey) private var wallpaperStamp = 0.0

    @State var draft = ""
    @State var selecting = false
    @State var picked: Set<UUID> = []
    @State private var searching = false
    @State private var showInfo = false
    @State var viewer: ImageViewerItem? = nil
    @State var toast: String? = nil
    @State var scrollTarget: UUID? = nil
    @State var visibleLimit = 120
    @State var atBottom = true
    @State var keyboardShown = false
    @State var pinBottom = 0
    @State var panel: Composer.Panel? = nil
    @State var inputFocused = false
    /// 点引用跳到原文时，原文闪一下
    @State var highlighted: UUID? = nil
    /// 长按「选择文字」时要框选的那段话
    @State var selectableText: SelectableTextItem? = nil
    /// 正在引用的那句话（长按消息 → 引用）
    @State var quoting: String? = nil
    @State var quotingID: UUID? = nil
    /// 是否跟着最新消息走：你往上翻看记录时不打扰，回到底部或发消息后重新跟随
    @State var follow = true
    /// 键盘高度：表情 / 加号面板做成一样高，切换时输入框不跳
    @AppStorage(Prefs.keyboardHeight) private var keyboardHeight = 336.0
    /// 页头下沿、输入栏上沿的位置：消息在这两处淡出（见 ChatEdgeMask）
    @State var headerBottom: CGFloat = 0
    @State var barTop: CGFloat = 0
    static let space = "chatContent"

    var personaMap: [UUID: Persona] {
        Dictionary(personas.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var members: [Persona] { convo.memberIDs.compactMap { personaMap[$0] } }

    /// 这个对话实际用的背景（自己设的优先，否则跟随全局）
    private var wallpaper: (index: Int, owner: UUID?) {
        _ = wallpaperStamp
        return WallpaperStore.resolve(for: convo.id, global: globalWallpaper)
    }

    /// 面板高度 = 键盘高度 - 底部安全区（面板背景再往下铺满安全区）：键盘和面板互换时输入框停在同一个位置
    var panelHeight: CGFloat {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let bottom = window?.safeAreaInsets.bottom ?? 34
        return max(250, keyboardHeight - bottom)
    }

    var body: some View {
        let paper = wallpaper
        content(paper: paper)
            // 背景决定文字深浅：「夜墨」和暗的照片按深色排版，亮的照片按浅色排版，名字和时间才看得清
            .environment(\.colorScheme, scheme(for: paper))
    }

    private func scheme(for paper: (index: Int, owner: UUID?)) -> ColorScheme {
        if paper.index == WallpaperStore.Choice.night.rawValue { return .dark }
        if paper.index == WallpaperStore.Choice.photo.rawValue, let light = WallpaperStore.luminance(for: paper.owner) {
            if light > 0.62 { return .light }
            if light < 0.38 { return .dark }
        }
        return systemScheme
    }

    // MARK: - 外框

    /// 整页：叠好的几层，加上进出聊天时的收尾、引擎的提示和几个弹出页
    private func content(paper: (index: Int, owner: UUID?)) -> some View {
        keyboardAware(paper: paper)
            // 重新生成没成功：旧的那条还在，轻轻提示一句
            .onChange(of: engine.redoFailed.contains(convo.id)) { _, failed in
                guard failed else { return }
                engine.redoFailed.remove(convo.id)
                flash("没能重新生成，原来的回复还在")
            }
            // 引擎要提示的一句话（比如语音额度用完了）
            .onChange(of: engine.notices[convo.id]) { _, text in
                guard let text else { return }
                engine.notices[convo.id] = nil
                flash(text)
            }
            .onAppear {
                router.openConversation = convo.id
                // 不在这个聊天时重新生成失败过：那条旧回复本来就在，不用再提示
                engine.redoFailed.remove(convo.id)
                convo.lastReadAt = .now
                draft = convo.draft
                // 截图：直接打开表情面板
                if DemoMode.isOn && DemoMode.screen == "stickers" { panel = .stickers }
            }
            .onDisappear {
                // 离开聊天时把键盘和面板收好，回到列表或别的页面不会残留
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                panel = nil
                if router.openConversation == convo.id { router.openConversation = nil }
                convo.draft = draft
                convo.lastReadAt = .now
                context.persist()
            }
            .sheet(isPresented: $showInfo) {
                GroupInfoSheet(convo: convo)
                    .presentationCornerRadius(Radius.sheet)
                    .presentationBackground(Palette.paper)
            }
            .fullScreenCover(item: $viewer) { ImageViewer(item: $0) }
            .sheet(item: $selectableText) { item in
                SelectableTextSheet(text: item.text)
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(Radius.sheet)
                    .presentationBackground(Palette.paper)
            }
    }

    /// 叠好的几层，加上顶上的轻提示，并实时跟着键盘的升降
    private func keyboardAware(paper: (index: Int, owner: UUID?)) -> some View {
        layers(paper: paper)
            .coordinateSpace(name: Self.space)
            .overlay(alignment: .top) { toastBanner }
            .toolbar(.hidden, for: .navigationBar)
            // 实时记下键盘高度：中文输入法的候选栏会让键盘变高变矮，面板跟着一样高，切换时才不会跳
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let screen = UIScreen.main.bounds.height
                let visible = screen - frame.minY
                if visible > 200 && abs(visible - keyboardHeight) > 1 { keyboardHeight = visible }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                keyboardShown = true
                // 键盘已经升到和面板一样高：悄悄撤掉面板，看起来就是面板直接变成了键盘。
                // 只在键盘是给输入框弹的时候才撤（表情面板里新建分类弹出的输入框不算，否则面板会被关掉）
                if panel != nil && inputFocused {
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { panel = nil }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in keyboardShown = false }
    }

    /// 从下往上：背景、消息列表（上下两头淡出）、页头、输入栏；搜索打开时盖在最上面
    private func layers(paper: (index: Int, owner: UUID?)) -> some View {
        ZStack {
            ChatWallpaper(index: paper.index, owner: paper.owner)
                .id("\(paper.index)-\(paper.owner?.uuidString ?? "")-\(wallpaperStamp)")
                .transition(.opacity)
            // 提前排好的主动消息到点就出现（见 PlannedSchedule）；判断用的始终是「现在」
            TimelineView(PlannedSchedule(convo)) { _ in
                messageList(now: .now)
            }
            // 滚到页头、输入栏那里的消息一边变糊一边变透明，到名字那一行完全看不见（照灵感视频）。
            // 透明度靠这层遮罩，模糊是每条消息按自己的位置糊（见 edgeBlur）；都按页头下沿、输入栏上沿量（同一个坐标系），
            // 键盘、面板升起时跟着走。不用系统的模糊：它在进出场动画里画不出来，只能等进去以后再加，会突然糊一下
            .mask { ChatEdgeMask(headerBottom: headerBottom, barTop: barTop) }
            .safeAreaInset(edge: .top, spacing: 0) {
                header.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).maxY } action: { headerBottom = $0 }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: { barTop = $0 }
            }
            // 面板开着时，键盘升起不推动输入框：面板和键盘一样高，两者直接互换
            .ignoresSafeArea(.keyboard, edges: panel != nil ? .bottom : [])

            if searching {
                ChatSearchView(convo: convo, members: members, personaMap: personaMap) { target in
                    withAnimation(Motion.spring) { searching = false }
                    if let target { scrollTarget = target }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .zIndex(2)
            }
        }
    }

    // MARK: - 页头

    private var header: some View {
        HStack(alignment: .top) {
            Button { router.closeChat() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("返回")
            Spacer()
            Button {
                if convo.isGroup { showInfo = true } else if let p = members.first { router.open(.momentsOf(p.id)) }
            } label: {
                VStack(spacing: 4) {
                    if convo.isGroup {
                        StackedAvatars(members: members, size: 40, includeMe: true)
                    } else {
                        AvatarView(persona: members.first, size: 56)
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                    }
                    Text(convo.displayTitle(members)).font(Typo.serif(15, .medium)).foregroundStyle(Palette.ink)
                    if selecting {
                        Text("已选 \(picked.count) 条").font(.system(size: 11)).foregroundStyle(Palette.inkSoft)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button { withAnimation(Motion.spring) { searching = true } } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("搜索聊天记录")
        }
        .padding(.horizontal, Space.tight)
        .padding(.bottom, Space.tight)
    }
}
