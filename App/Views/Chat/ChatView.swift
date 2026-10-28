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
    @State private var panel: Composer.Panel?
    @State private var inputFocused = false
    /// 点引用跳到原文时，原文闪一下
    @State private var highlighted: UUID?
    /// 长按「选择文字」时要框选的那段话
    @State private var selectableText: SelectableTextItem?
    /// 正在引用的那句话（长按消息 → 引用）
    @State private var quoting: String?
    @State private var quotingID: UUID?
    /// 是否跟着最新消息走：你往上翻看记录时不打扰，回到底部或发消息后重新跟随
    @State private var follow = true
    /// 键盘高度：表情 / 加号面板做成一样高，切换时输入框不跳
    @AppStorage(Prefs.keyboardHeight) private var keyboardHeight = 336.0

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
            // 背景决定文字深浅：「夜墨」和暗的照片按深色排版，亮的照片按浅色排版，名字和时间才看得清
            .environment(\.colorScheme, scheme(for: paper))
    }

    private func scheme(for paper: (index: Int, owner: UUID?)) -> ColorScheme {
        if paper.index == 2 { return .dark }
        if paper.index == 3, let light = WallpaperStore.luminance(for: paper.owner) {
            if light > 0.62 { return .light }
            if light < 0.38 { return .dark }
        }
        return systemScheme
    }

    private func content(paper: (index: Int, owner: UUID?)) -> some View {
        ZStack {
            ChatWallpaper(index: paper.index, owner: paper.owner)
                .id("\(paper.index)-\(paper.owner?.uuidString ?? "")-\(wallpaperStamp)")
                .transition(.opacity)
            // 提前排好的主动消息到点就出现（见 PlannedSchedule）；判断用的始终是「现在」
            TimelineView(PlannedSchedule(convo)) { _ in
                messageList(now: .now)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                // 顶部：屏幕最上面最模糊，往下渐渐减弱，到头像一半左右已经基本清晰
                header.background {
                    ChatVeil(edge: .top, shown: router.chatSettled)
                        .padding(.bottom, -28)
                        .ignoresSafeArea(edges: .top)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar.background {
                    ChatVeil(edge: .bottom, shown: router.chatSettled)
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
                Text(LocalizedStringKey(toast))
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
            // 键盘已经升到和面板一样高：悄悄撤掉面板，看起来就是面板直接变成了键盘。
            // 只在键盘是给输入框弹的时候才撤（表情面板里新建分类弹出的输入框不算，否则面板会被关掉）
            if panel != nil && inputFocused {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { panel = nil }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in keyboardShown = false }
        // 重新生成没成功：旧的那条还在，轻轻提示一句
        .onChange(of: engine.redoFailed.contains(convo.id)) { _, failed in
            guard failed else { return }
            engine.redoFailed.remove(convo.id)
            flash("没能重新生成，原来的回复还在")
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

    // MARK: - 消息

    private func messageList(now: Date) -> some View {
        let all = convo.visibleMessages(at: now)
        // 只排版最近的一段，避免懒加载估算高度导致跳动；更早的按需加载
        let window = Array(all.suffix(visibleLimit))
        // 「正在输入」的小点不按时间排，永远在最底下（像 iMessage）：你这时再发消息，会插在小点上面
        let typing = window.last { isTypingOnly($0) }
        let messages = window.filter { !isTypingOnly($0) }
        // 打字的那条接在最后：和打好后的消息是同一行（同一个 id），小点会在原地变成文字，而不是删掉再冒出新的一行
        var rows = ChatRow.build(messages)
        if let typing {
            let first = !(messages.last?.role == .assistant && messages.last?.personaID == typing.personaID)
            rows.append(ChatRow(id: typing.id.uuidString, kind: .message(typing, first: first)))
        }
        let live = (typing ?? messages.last).flatMap { engine.buffers[$0.id] }
        let receipt = readReceiptTarget(messages)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if all.count > window.count {
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
                            // 从引用跳过来时，原文这一条轻轻亮一下
                            .background {
                                RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                                    .fill(Palette.highlight.opacity(highlighted == m.id ? 0.6 : 0))
                                    .padding(-4)
                            }
                            .padding(.top, first ? 14 : 4)
                            // 刚发出、刚收到的：这一行慢慢撑开，气泡从自己那一边的下角冒出来
                            .riseIn(fresh: now.timeIntervalSince(m.createdAt) < 3,
                                    anchor: m.role == .user ? .bottomTrailing : .bottomLeading)
                            .id(m.id)
                            if m.id == receipt { ReadReceipt() }
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
            .onScrollPhaseChange { old, phase in
                switch phase {
                case .interacting:
                    // 手指一碰聊天记录，表情/加号面板就收起（和键盘一样）
                    if panel != nil { withAnimation(Motion.spring) { panel = nil } }
                case .idle:
                    // 只有你自己翻动后停下来才重新判断：在底部附近就继续跟随，翻到上面就不打扰
                    //（程序自动滚动、键盘升降引起的滚动不算，免得误以为你往上翻了）
                    if old == .interacting || old == .decelerating { follow = atBottom }
                default:
                    break
                }
            }
            .onAppear {
                // 打开聊天（包括从顶部提示点进来）就停在最新的消息。图片解码后变高，由「内容变高也贴着底部」跟上；
                // 不再隔一会儿补滚几次：那几下正好落在进场动画里，看起来像抽了一下
                follow = true
                proxy.scrollTo("bottom", anchor: .bottom)
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
                // 自己发消息后回到底部；对方的新消息、打字的小点在跟随时由「内容变高也贴着底部」自己跟上，
                // 不再额外滚一次（两个动画互相拉扯，看起来会卡一下）
                guard messages.last?.role == .user else { return }
                follow = true
                // 和气泡撑开用同一条曲线：滚动和上面让开是同一个动作，不会一快一慢
                withAnimation(Motion.bubble) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: keyboardShown) { _, shown in
                // 键盘升起：一定回到最新；键盘收起：在跟随时也贴回底部，不会留下一大片空白
                if shown { follow = true }
                guard follow else { return }
                withAnimation(Motion.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: panel == nil) { _, closed in
                // 表情/加号面板收起后，在跟随时贴回底部
                guard closed, follow else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(60))
                    withAnimation(Motion.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                follow = false
                withAnimation(Motion.spring) { proxy.scrollTo(target, anchor: .center) }
                scrollTarget = nil
            }
        }
    }

    /// TA 已经开始回、但这句还没打完（只显示跳动的小点）。只看「还藏着」这个开关，不读正文，免得每冒一个字整个列表都重排
    private func isTypingOnly(_ m: Message) -> Bool {
        guard m.status == .streaming, let buffer = engine.buffers[m.id] else { return false }
        return buffer.hold && buffer.steps.isEmpty
    }

    /// 「已读」挂在哪条下面：你最后一条、TA 已经看过的消息。TA 正在打字（只有跳动的小点）时还留着，
    /// 等 TA 第一句话真的冒出来才淡出，和 iMessage 一样
    private func readReceiptTarget(_ messages: [Message]) -> UUID? {
        guard let index = messages.lastIndex(where: { $0.role == .user && !$0.recalled }) else { return nil }
        let mine = messages[index]
        guard mine.readAt != nil else { return nil }
        let replied = messages[(index + 1)...].contains { m in
            guard m.status == .streaming else { return true }
            // 只看「还藏着」这一个开关，不读正文，免得每冒一个字整个列表都重排一次
            guard let buffer = engine.buffers[m.id] else { return false }
            return !buffer.hold || !buffer.steps.isEmpty
        }
        return replied ? nil : mine.id
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
                context.persist()
                flash("已加入待办")
            },
            openImages: { attachments, index in
                viewer = ImageViewerItem(attachments: attachments, index: index)
            },
            retry: { m in engine.regenerate(m, in: convo, members: members, context: context) },
            stop: { engine.stop(convo) },
            quote: { m in
                let who = m.role == .user ? "我" : (m.personaID.flatMap { personaMap[$0]?.name } ?? "AI")
                let body: String = switch m.kind {
                case .images: "[图片]" + (m.content.isEmpty ? "" : " " + m.content)
                case .file: "[文件] " + m.sortedAttachments.map(\.fileName).joined(separator: "、")
                case .sticker: "[表情]"
                case .voice: "[语音] " + m.content
                case .note, .text: m.content
                }
                withAnimation(Motion.spring) { quoting = "\(who)：" + body.replacingOccurrences(of: "\n", with: " ").prefix(120) }
                quotingID = m.id
                pinBottom += 1
            },
            recall: { m in
                // 撤回：留一行「你撤回了一条消息」；TA 还没开口的话会重新看一遍再回
                withAnimation(Motion.bubble) { m.recalled = true }
                context.persist()
                engine.reconsider(convo, members: members, context: context)
            },
            openQuote: { m in
                // 点引用：跳到原文并让它亮一下；原文太早没加载时先把更早的消息加载出来
                let all = convo.visibleMessages()
                let earlier = all.filter { $0.createdAt < m.createdAt }
                guard let target = ReplyText.source(ofQuote: m.quote, id: m.quoteID, in: earlier) else {
                    flash("原消息已经不在了")
                    return
                }
                let id = target.id
                if let index = all.firstIndex(where: { $0.id == id }) { visibleLimit = max(visibleLimit, all.count - index + 10) }
                // 等更早的消息排好版再滚过去
                Task {
                    try? await Task.sleep(for: .milliseconds(60))
                    scrollTarget = id
                }
                withAnimation(Motion.spring) { highlighted = id }
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    withAnimation(Motion.glide) { if highlighted == id { highlighted = nil } }
                }
            },
            selectText: { text in selectableText = SelectableTextItem(text: text) },
            edit: { m in
                // 编辑：把原话（连同引用）放回输入框，原消息去掉，改好再发
                quotingID = m.quoteID
                withAnimation(Motion.spring) {
                    draft = m.content
                    quoting = m.quote.isEmpty ? nil : m.quote
                    context.delete(m)
                }
                context.persist()
                engine.reconsider(convo, members: members, context: context)
                inputFocused = true
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
                     onSend: send, onExpand: { pinBottom += 1 }, inputFocused: $inputFocused)
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
        let quoteID = quoting == nil ? nil : quotingID
        withAnimation(Motion.spring) { quoting = nil }
        quotingID = nil
        let deliver = { engine.send(text, kind: kind, attachments: attachments, quote: quote, quoteID: quoteID, in: convo, members: members, context: context) }
        guard members.contains(where: \.canWork), AppLock.shared.needsWorkConfirm else { return deliver() }
        // 会操作电脑的角色：开了保护就先确认是你本人；没通过就把话放回输入框
        Task {
            if await AppLock.shared.confirmWork() {
                deliver()
            } else {
                if kind == .text { draft = text }
                flash("没有通过验证")
            }
        }
    }

    private func deleteMessages(_ ids: Set<UUID>) {
        withAnimation(Motion.spring) {
            for m in convo.messages ?? [] where ids.contains(m.id) && engine.buffers[m.id] == nil {
                context.delete(m)
            }
            context.persist()
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

/// 聊天页和聊天列表的刷新时间表：每分钟走一次，另外在提前排好的消息（主动消息、追问、约定）到点的那一刻也走一次。
/// 这样通知弹出来时，点进聊天就已经能看到那句话，出现时也和别的气泡一样冒出来，不用等到下一个整分钟
struct PlannedSchedule: TimelineSchedule {
    let planned: [Date]

    init(_ convo: Conversation) {
        planned = convo.plannedMessages().map(\.createdAt)
    }

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var minute = Calendar.current.dateInterval(of: .minute, for: start)?.start ?? start
        var upcoming = planned.filter { $0 > start }.sorted()[...]
        var first = true
        return AnyIterator {
            if first {
                first = false
                return start
            }
            let next = minute.addingTimeInterval(60)
            if let due = upcoming.first, due < next {
                upcoming.removeFirst()
                return due
            }
            minute = next
            return next
        }
    }
}
