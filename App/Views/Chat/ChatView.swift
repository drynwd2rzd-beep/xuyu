import SwiftUI
import SwiftData

struct ChatView: View {
    @Bindable var convo: Conversation
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatEngine.self) private var engine
    @Environment(RelayClient.self) private var relay
    @Environment(Router.self) private var router
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @Environment(\.colorScheme) private var systemScheme
    @AppStorage(Prefs.wallpaper) private var globalWallpaper = 0
    @AppStorage(WallpaperStore.stampKey) private var wallpaperStamp = 0.0

    @State private var draft = ""
    @State private var selecting = false
    @State private var picked: Set<UUID> = []
    @State private var searching = false
    @State private var showInfo = false
    @State private var viewer: ImageViewerItem?
    @State private var toast: String?
    @State private var scrollTarget: UUID?
    @State private var visibleLimit = 120
    @State private var atBottom = true
    @State private var keyboardShown = false
    @State private var pinBottom = 0
    @State private var entered = false
    @State private var panel: Composer.Panel?
    /// 正在引用的那句话（长按消息 → 引用）
    @State private var quoting: String?
    /// 是否跟着最新消息走：你往上翻看记录时不打扰，回到底部或发消息后重新跟随
    @State private var follow = true
    /// 键盘高度：表情 / 加号面板做成一样高，切换时输入框不跳
    @AppStorage("keyboardHeight") private var keyboardHeight = 336.0

    private var personaMap: [UUID: Persona] {
        Dictionary(personas.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var members: [Persona] { convo.memberIDs.compactMap { personaMap[$0] } }

    /// 这个对话实际用的背景（自己设的优先，否则跟随全局）
    private var wallpaper: (index: Int, owner: UUID?) {
        _ = wallpaperStamp
        return WallpaperStore.resolve(for: convo.id, global: globalWallpaper)
    }

    var body: some View {
        let paper = wallpaper
        content(paper: paper)
            // 「夜墨」背景下整页按深色排版，文字和气泡才看得清
            .environment(\.colorScheme, paper.index == 2 ? .dark : systemScheme)
    }

    private func content(paper: (index: Int, owner: UUID?)) -> some View {
        ZStack {
            ChatWallpaper(index: paper.index, owner: paper.owner)
                .id("\(paper.index)-\(paper.owner?.uuidString ?? "")-\(wallpaperStamp)")
                .transition(.opacity)
            // 每分钟刷新一次，让提前排好的主动消息到点出现；判断用的始终是「现在」
            TimelineView(.everyMinute) { _ in
                messageList(now: .now)
                    // 进入聊天：消息从下方轻轻浮上来、慢慢变清晰
                    .opacity(entered ? 1 : 0)
                    .offset(y: entered ? 0 : 22)
                    .blur(radius: entered ? 0 : 6)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                // 顶部：屏幕最上面最模糊，往下渐渐减弱，到头像一半左右已经基本清晰
                header.background {
                    ChatVeil(edge: .top)
                        .padding(.bottom, -28)
                        .ignoresSafeArea(edges: .top)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar.background {
                    ChatVeil(edge: .bottom)
                        .padding(.top, -24)
                        .ignoresSafeArea(edges: .bottom)
                }
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
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.onNoir)
                    .padding(.horizontal, Space.card)
                    .frame(height: 36)
                    .background(Palette.noir, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
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
            // 键盘已经升到和面板一样高：悄悄撤掉面板，看起来就是面板直接变成了键盘
            if panel != nil {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { panel = nil }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in keyboardShown = false }
        .onAppear {
            router.openConversation = convo.id
            convo.lastReadAt = .now
            draft = convo.draft
            withAnimation(.spring(duration: 0.6, bounce: 0.08).delay(0.08)) { entered = true }
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
            try? context.save()
        }
        .sheet(isPresented: $showInfo) {
            GroupInfoSheet(convo: convo)
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        .fullScreenCover(item: $viewer) { ImageViewer(item: $0) }
    }

    // MARK: - 页头

    private var header: some View {
        HStack(alignment: .top) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("返回")
            Spacer()
            Button {
                if convo.isGroup { showInfo = true } else if let p = members.first { router.open(.persona(p.id)) }
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
                // 进入聊天：头像轻轻放大到位
                .scaleEffect(entered ? 1 : 0.86)
                .opacity(entered ? 1 : 0)
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

    // MARK: - 消息

    private func messageList(now: Date) -> some View {
        let all = convo.visibleMessages(at: now)
        // 只排版最近的一段，避免懒加载估算高度导致跳动；更早的按需加载
        let messages = Array(all.suffix(visibleLimit))
        let rows = ChatRow.build(messages)
        let live = messages.last.flatMap { engine.buffers[$0.id] }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if all.count > messages.count {
                        Button("查看更早的消息") { visibleLimit += 120 }
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.inkSoft)
                            .padding(.vertical, Space.item)
                    }
                    ForEach(rows) { row in
                        switch row.kind {
                        case .stamp(let date):
                            Text(date.separatorStamp)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.inkSoft)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Space.item)
                        case .message(let m, _) where m.recalled:
                            RecalledLine(message: m, onEdit: actions.edit)
                                .id(m.id)
                        case .message(let m, let first):
                            MessageRow(message: m,
                                       persona: m.personaID.flatMap { personaMap[$0] },
                                       isGroup: convo.isGroup,
                                       first: first,
                                       selecting: selecting,
                                       picked: picked.contains(m.id),
                                       actions: actions)
                            .riseIn(fresh: now.timeIntervalSince(m.createdAt) < 3)
                            .padding(.top, first ? 14 : 4)
                            .id(m.id)
                        }
                    }
                    Color.clear.frame(height: Space.item).id("bottom")
                }
                .padding(.horizontal, Space.item)
                // 回复逐字出现时，跟着往下走（你往上翻看时不打扰）
                .background { StreamFollower(buffer: live) { if follow { proxy.scrollTo("bottom", anchor: .bottom) } } }
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // 跟随最新消息时，内容变高（新消息、图片加载完）也保持贴着底部
            .defaultScrollAnchor(follow ? .bottom : nil, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            // 点一下聊天区域：收起表情/加号面板和键盘
            .simultaneousGesture(TapGesture().onEnded {
                if panel != nil { withAnimation(Motion.spring) { panel = nil } }
                if keyboardShown {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            })
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting:
                    // 手指一碰聊天记录，表情/加号面板就收起（和键盘一样）
                    if panel != nil { withAnimation(Motion.spring) { panel = nil } }
                case .idle:
                    // 停下来时在底部附近就继续跟随，翻到上面就不打扰
                    follow = atBottom
                default:
                    break
                }
            }
            .onAppear {
                // 打开聊天（包括从顶部提示点进来）就停在最新的消息；图片解码后高度会变，稍后再对齐几次
                follow = true
                proxy.scrollTo("bottom", anchor: .bottom)
                Task {
                    for delay in [60, 300, 700] {
                        try? await Task.sleep(for: .milliseconds(delay))
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .onChange(of: pinBottom) {
                // 点输入框、打开表情或加号面板：聊天跟着到最底下
                follow = true
                Task {
                    try? await Task.sleep(for: .milliseconds(30))
                    withAnimation(Motion.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height + geo.contentInsets.bottom - 120
            } action: { _, value in
                atBottom = value
            }
            .onChange(of: messages.last?.id) {
                // 自己发消息后总是回到底部；对方的新消息在跟随时滚到最新一条
                if messages.last?.role == .user { follow = true }
                guard follow else { return }
                withAnimation(Motion.glide) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: keyboardShown) { _, shown in
                if shown { withAnimation(Motion.spring) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(Motion.spring) { proxy.scrollTo(target, anchor: .center) }
                scrollTarget = nil
            }
        }
    }

    private var actions: MessageActions {
        MessageActions(
            copy: { text in
                UIPasteboard.general.string = text
                flash("已复制")
            },
            select: { m in
                withAnimation(Motion.spring) {
                    selecting = true
                    picked = [m.id]
                }
            },
            toggle: { m in
                if picked.contains(m.id) { picked.remove(m.id) } else { picked.insert(m.id) }
            },
            delete: { m in deleteMessages([m.id]) },
            regenerate: { m in engine.regenerate(m, in: convo, members: members, context: context) },
            addTodo: { text in
                let line = text.components(separatedBy: "\n").first(where: { !$0.trimmed.isEmpty })?.trimmed ?? text
                let item = TodoItem(title: String(line.prefix(60)), notes: text.count > 60 ? text : "")
                context.insert(item)
                try? context.save()
                flash("已加入待办")
            },
            openImages: { attachments, index in
                viewer = ImageViewerItem(attachments: attachments, index: index)
            },
            retry: { m in engine.regenerate(m, in: convo, members: members, context: context) },
            quote: { m in
                let who = m.role == .user ? "我" : (m.personaID.flatMap { personaMap[$0]?.name } ?? "AI")
                let body: String = switch m.kind {
                case .images: "[图片]" + (m.content.isEmpty ? "" : " " + m.content)
                case .file: "[文件] " + m.sortedAttachments.map(\.fileName).joined(separator: "、")
                case .sticker: "[表情]"
                case .note, .text: m.content
                }
                withAnimation(Motion.spring) { quoting = "\(who)：" + body.replacingOccurrences(of: "\n", with: " ").prefix(120) }
                pinBottom += 1
            },
            recall: { m in
                // 撤回：留一行「你撤回了一条消息」；TA 还没开口的话会重新看一遍再回
                withAnimation(Motion.spring) { m.recalled = true }
                try? context.save()
                engine.reconsider(convo, members: members, context: context)
            },
            edit: { m in
                // 编辑：把原话放回输入框，原消息去掉，改好再发
                withAnimation(Motion.spring) {
                    draft = m.content
                    context.delete(m)
                }
                try? context.save()
                engine.reconsider(convo, members: members, context: context)
                pinBottom += 1
            }
        )
    }

    // MARK: - 底部

    @ViewBuilder
    private var bottomBar: some View {
        if selecting {
            HStack {
                Button("取消") {
                    withAnimation(Motion.spring) {
                        selecting = false
                        picked = []
                    }
                }
                .font(.system(size: 15))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, Space.card)
                Spacer()
                Text("已选 \(picked.count) 条").font(.system(size: 14)).foregroundStyle(Palette.ink2)
                Spacer()
                Button {
                    deleteMessages(picked)
                    withAnimation(Motion.spring) {
                        selecting = false
                        picked = []
                    }
                } label: {
                    Text("删除")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: Space.control)
                        .background(picked.isEmpty ? Palette.danger.opacity(0.4) : Palette.danger, in: Capsule())
                }
                .disabled(picked.isEmpty)
            }
            .padding(Space.tight)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
            .padding(.horizontal, Space.page)
            .padding(.bottom, Space.tight)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            Composer(draft: $draft, panel: $panel, quote: $quoting, panelHeight: panelHeight, convo: convo, members: members,
                     onSend: send, onExpand: { pinBottom += 1 })
        }
    }

    /// 面板高度 = 键盘高度 - 底部安全区（面板背景再往下铺满安全区）：键盘和面板互换时输入框停在同一个位置
    private var panelHeight: CGFloat {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let bottom = window?.safeAreaInsets.bottom ?? 34
        return max(250, keyboardHeight - bottom)
    }

    private func send(_ text: String, kind: MessageKind, attachments: [OutgoingAttachment]) {
        let quote = quoting ?? ""
        withAnimation(Motion.spring) { quoting = nil }
        engine.send(text, kind: kind, attachments: attachments, quote: quote, in: convo, members: members, context: context)
    }

    private func deleteMessages(_ ids: Set<UUID>) {
        withAnimation(Motion.spring) {
            for m in convo.messages ?? [] where ids.contains(m.id) && engine.buffers[m.id] == nil {
                context.delete(m)
            }
            try? context.save()
        }
    }

    private func flash(_ text: String) {
        withAnimation(Motion.spring) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Motion.spring) { toast = nil }
        }
    }
}

/// 只观察正在生成的那一条，字数变化时通知外面跟着滚动（不会让整个列表重绘）
private struct StreamFollower: View {
    let buffer: StreamBuffer?
    let follow: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: buffer?.text.count ?? 0) { follow() }
            .onChange(of: buffer?.reasoning.count ?? 0) { follow() }
    }
}

/// 消息列表的行：时间分隔 / 消息（连续同一个人的消息合成一组）
struct ChatRow: Identifiable {
    enum Kind {
        case stamp(Date)
        case message(Message, first: Bool)
    }

    let id: String
    let kind: Kind

    static func build(_ messages: [Message]) -> [ChatRow] {
        var rows: [ChatRow] = []
        var prev: Message?
        for m in messages {
            var first = true
            if let prev {
                let gap = m.createdAt.timeIntervalSince(prev.createdAt)
                if gap > 600 {
                    rows.append(ChatRow(id: "t-\(m.id)", kind: .stamp(m.createdAt)))
                } else {
                    let same = prev.role == m.role && prev.personaID == m.personaID
                    first = !(same && gap < 180)
                }
            } else {
                rows.append(ChatRow(id: "t-\(m.id)", kind: .stamp(m.createdAt)))
            }
            rows.append(ChatRow(id: m.id.uuidString, kind: .message(m, first: first)))
            prev = m
        }
        return rows
    }
}
