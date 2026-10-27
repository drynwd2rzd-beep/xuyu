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
    @AppStorage(Prefs.wallpaper) private var wallpaper = 0

    @State private var draft = ""
    @State private var selecting = false
    @State private var picked: Set<UUID> = []
    @State private var searching = false
    @State private var showInfo = false
    @State private var viewer: ImageViewerItem?
    @State private var toast: String?
    @State private var scrollTarget: UUID?

    private var personaMap: [UUID: Persona] {
        Dictionary(personas.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var members: [Persona] { convo.memberIDs.compactMap { personaMap[$0] } }

    var body: some View {
        ZStack {
            ChatWallpaper(index: wallpaper)
            TimelineView(.everyMinute) { ctx in
                messageList(now: ctx.date)
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }

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
        .onAppear {
            router.openConversation = convo.id
            convo.lastReadAt = .now
            draft = convo.draft
        }
        .onDisappear {
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
                        StackedAvatars(members: members, size: 34)
                    } else {
                        AvatarView(persona: members.first, size: 46)
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                    }
                    HStack(spacing: 5) {
                        Text(convo.displayTitle(members)).font(Typo.serif(15, .medium)).foregroundStyle(Palette.ink)
                        if !convo.isGroup && relay.isConnected {
                            Circle().fill(Palette.ink).frame(width: 5, height: 5)
                        }
                    }
                    if let typingID = engine.typing[convo.id], let p = personaMap[typingID] {
                        Text(convo.isGroup ? "\(p.name) 正在输入…" : "正在输入…")
                            .font(.system(size: 11)).foregroundStyle(Palette.inkSoft)
                            .transition(.opacity)
                    } else if selecting {
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
        .padding(.bottom, Space.item)
        .background {
            LinearGradient(stops: [.init(color: Palette.paper, location: 0.6), .init(color: Palette.paper.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        }
        .animation(Motion.spring, value: engine.typing[convo.id])
    }

    // MARK: - 消息

    private func messageList(now: Date) -> some View {
        let messages = convo.visibleMessages(at: now)
        let rows = ChatRow.build(messages)
        let lastAI = messages.last { $0.role == .assistant && $0.status == .done }?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        switch row.kind {
                        case .stamp(let date):
                            Text(date.separatorStamp)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.inkSoft)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Space.item)
                        case .message(let m, let first):
                            MessageRow(message: m,
                                       persona: m.personaID.flatMap { personaMap[$0] },
                                       isGroup: convo.isGroup,
                                       first: first,
                                       showActions: m.id == lastAI && !engine.isBusy(convo),
                                       selecting: selecting,
                                       picked: picked.contains(m.id),
                                       actions: actions)
                            .padding(.top, first ? 14 : 4)
                            .id(m.id)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    Color.clear.frame(height: Space.item).id("bottom")
                }
                .padding(.horizontal, Space.item)
                .animation(Motion.spring, value: messages.count)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) {
                withAnimation(Motion.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .task {
                // 输入栏高度确定后再滚到底，避免最后一条被盖住
                try? await Task.sleep(for: .milliseconds(150))
                proxy.scrollTo("bottom", anchor: .bottom)
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
            retry: { m in engine.regenerate(m, in: convo, members: members, context: context) }
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
            Composer(draft: $draft, convo: convo, members: members, busy: engine.isBusy(convo),
                     onSend: send, onStop: { engine.stop(convo) })
        }
    }

    private func send(_ text: String, kind: MessageKind, attachments: [OutgoingAttachment]) {
        engine.send(text, kind: kind, attachments: attachments, in: convo, members: members, context: context)
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
