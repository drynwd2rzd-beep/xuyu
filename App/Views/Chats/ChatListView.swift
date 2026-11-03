import SwiftUI
import SwiftData

struct ChatListView: View {
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @Environment(ChatEngine.self) private var engine
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @Query(sort: \DiaryEntry.day, order: .reverse) private var entries: [DiaryEntry]
    @State private var query = ""
    @State private var openRow: UUID?
    @State private var pendingRemoval: Conversation?
    /// 每一行现在在屏幕上的位置：点开聊天时从那一行飞进去。记在普通对象里，滚动时更新不会让列表重画
    @State private var rowFrames = RowFrames()

    private var personaMap: [UUID: Persona] {
        Dictionary(personas.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// 每位角色此刻的心情：TA 最近一篇写了心情的日记
    private var moods: [UUID: String] {
        var result: [UUID: String] = [:]
        for e in entries where e.author == .ai && !e.mood.isEmpty {
            if let id = e.personaID, result[id] == nil { result[id] = e.mood }
        }
        return result
    }

    private func members(_ convo: Conversation) -> [Persona] {
        convo.memberIDs.compactMap { personaMap[$0] }
    }

    private var visible: [Conversation] {
        let live = conversations.filter { convo in
            // 角色被删掉的单聊不显示
            convo.isGroup || !members(convo).isEmpty
        }
        let ordered = live.filter(\.pinned) + live.filter { !$0.pinned }
        let q = query.trimmed
        guard !q.isEmpty else { return ordered }
        return ordered.filter { convo in
            convo.displayTitle(members(convo)).localizedCaseInsensitiveContains(q)
                || (convo.lastVisible()?.content.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        // 照设计稿：「聊天 Colloquia」，一条浅灰的搜索框，下面一行行直接铺在白底上（不包卡片、不加线）
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeading(title: "聊天", latin: "Colloquia") {
                    Button { router.open(.personas) } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: Icon.compose))
                            .foregroundStyle(Palette.ink)
                            .frame(width: Space.control, height: Space.control)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .accessibilityLabel("新建聊天")
                }
                SearchField(text: $query, placeholder: "搜索聊天记录")
                    .padding(.horizontal, Space.page)
                    .padding(.bottom, Space.tight)
                list
            }
            .padding(.bottom, Space.bookBottom)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private var list: some View {
        let items = visible
        VStack(spacing: 0) {
            ForEach(items) { convo in
                SwipeRow(id: convo.id, openID: $openRow,
                         leading: SwipeAction(icon: convo.pinned ? "pin.slash.fill" : "pin.fill",
                                              title: convo.pinned ? "取消置顶" : "置顶", tint: Palette.ink) { togglePin(convo) },
                         trailing: SwipeAction(icon: "trash.fill", title: convo.isGroup ? "删除" : "清空",
                                               tint: Palette.danger) { pendingRemoval = convo }) {
                    Button { router.open(.chat(convo.id), from: rowFrames.rects[convo.id]) } label: {
                        ConversationRow(convo: convo, members: members(convo), personaMap: personaMap,
                                        typing: engine.isBusy(convo), mood: convo.isGroup ? "" : moods[convo.memberIDs.first ?? UUID()] ?? "")
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrames.rects[convo.id] = $0 }
                    }
                    .buttonStyle(PressableRowStyle())
                    .accessibilityIdentifier("chatRow")
                }
                .contextMenu {
                    Button { togglePin(convo) } label: {
                        Label(convo.pinned ? "取消置顶" : "置顶", systemImage: convo.pinned ? "pin.slash" : "pin")
                    }
                    Button(role: .destructive) { pendingRemoval = convo } label: {
                        Label(convo.isGroup ? "删除群聊" : "清空聊天记录", systemImage: "trash")
                    }
                }
            }
            if items.isEmpty && !query.trimmed.isEmpty {
                Text("没有找到「\(query.trimmed)」")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.inkSoft)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            }
        }
        .animation(Motion.spring, value: items.map(\.id))
        .confirmationDialog(pendingRemoval?.isGroup == true ? "删除这个群聊？" : "清空聊天记录？",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible, presenting: pendingRemoval) { convo in
            Button(convo.isGroup ? "删除" : "清空", role: .destructive) {
                Task {
                    if convo.isGroup {
                        await Cleanup.deleteGroup(convo, context: context, engine: engine)
                    } else {
                        await Cleanup.clearChat(convo, context: context, engine: engine)
                    }
                }
            }
        } message: { convo in
            Text(convo.isGroup ? "群聊和里面的记录都会删除，无法恢复。" : "角色会保留，记录删除后无法恢复。")
        }
    }

    private func togglePin(_ convo: Conversation) {
        withAnimation(Motion.spring) { convo.pinned.toggle() }
        context.persist()
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        HStack(spacing: Space.tight) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.inkSoft)
            TextField(placeholder, text: $text)
                .font(.system(size: Typo.body))
                .foregroundStyle(Palette.ink)
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.faint)
                }
                .accessibilityLabel("清除")
            }
        }
        .padding(.horizontal, Space.section)
        .frame(height: Space.search)
        .background(Palette.card, in: Capsule())
    }
}

struct ConversationRow: View {
    let convo: Conversation
    let members: [Persona]
    let personaMap: [UUID: Persona]
    let typing: Bool
    /// TA 此刻的心情（最近一篇日记里写的；群聊没有）
    var mood = ""

    /// 未读小数字的底色：TA 心情的颜色
    private var tint: Color { MoodTint.glow(for: mood).m1 }

    var body: some View {
        TimelineView(PlannedSchedule(convo)) { _ in
            let last = convo.lastVisible(at: .now)
            let unread = convo.hasUnread(at: .now) ? convo.unreadCount(at: .now) : 0
            // 照设计稿：光球头像；名字后面跟 TA 此刻的心情小字；时间是淡淡的拉丁字；
            // TA 说的最后一句用宋体，你说的用系统字、前面带「你：」；未读是 TA 颜色的小数字
            HStack(spacing: Space.section) {
                ConversationAvatar(convo: convo, members: members, size: AvatarSize.list)
                VStack(alignment: .leading, spacing: Space.tiny) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.tight) {
                        Text(verbatim: convo.displayTitle(members))
                            .font(.system(size: Typo.body, weight: .medium))
                            .tracking(Typo.tracking)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        if !mood.isEmpty {
                            Text(verbatim: mood).font(.system(size: Typo.caption)).foregroundStyle(Palette.inkSoft)
                        }
                        if convo.pinned {
                            Image(systemName: "pin.fill").font(.system(size: Icon.pin)).foregroundStyle(Palette.faint)
                        }
                        Spacer(minLength: Space.tight)
                        if let last {
                            Text(verbatim: PostTime.label(last.createdAt, now: .now))
                                .font(Typo.serif(Typo.label))
                                .monospacedDigit()
                                .foregroundStyle(Palette.inkSoft)
                        }
                    }
                    HStack(spacing: Space.tight) {
                        let mine = last?.role == .user
                        Text(verbatim: typing ? String(localized: "正在输入…") : (mine ? String(localized: "你：") : "") + preview(last))
                            .font(mine || typing ? .system(size: Typo.label) : Typo.serif(Typo.label))
                            .foregroundStyle(mine ? Palette.inkSoft : Palette.ink2)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if unread > 0 {
                            Text(verbatim: "\(unread)")
                                .font(.system(size: Typo.caption))
                                .monospacedDigit()
                                .foregroundStyle(Palette.onPhoto)
                                .padding(.horizontal, Space.tiny)
                                .frame(minWidth: Space.badge, minHeight: Space.badge)
                                .background(tint, in: Capsule())
                        }
                    }
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.vertical, Space.section)
            .contentShape(Rectangle())
            // 旁白：名字、最新一句、未读几条一起读
            .accessibilityElement(children: .combine)
            .accessibilityValue(unread > 0 ? Text("未读") : Text(""))
        }
    }

    private func preview(_ last: Message?) -> String {
        guard let last else { return convo.isGroup ? "\(members.count) 位成员" : (members.first?.bio ?? "") }
        let body: String = switch last.kind {
        case .images: "[图片]"
        case .file: "[文件]"
        case .sticker: "[表情]"
        case .voice: "[语音]"
        case .nudge: last.role == .user ? String(localized: "你拍了拍\(last.content)") : String(localized: "拍了拍你")
        case .call: String(localized: "[语音通话] \(last.content)")
        case .note: "[想法] " + last.content
        case .text: last.content.isEmpty ? (last.status == .error ? "发送失败" : "…") : last.content
        }
        let flat = body.replacingOccurrences(of: "\n", with: " ")
        if convo.isGroup, last.role == .assistant, let name = last.personaID.flatMap({ personaMap[$0]?.name }) {
            return "\(name)：\(flat)"
        }
        return flat
    }
}

/// 聊天列表每一行在屏幕上的位置（普通对象：改它不会触发重画）
final class RowFrames {
    var rects: [UUID: CGRect] = [:]
}
