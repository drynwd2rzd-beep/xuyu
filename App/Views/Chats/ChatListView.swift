import SwiftUI
import SwiftData

struct ChatListView: View {
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @Environment(ChatEngine.self) private var engine
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @State private var query = ""

    private var personaMap: [UUID: Persona] {
        Dictionary(personas.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                PageTitle(title: "Chats") { EmptyView() }
                SearchField(text: $query, placeholder: "搜索")
                list
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.top)
            .padding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private var list: some View {
        let items = visible
        VStack(spacing: 0) {
            ForEach(items) { convo in
                Button { router.open(.chat(convo.id)) } label: {
                    ConversationRow(convo: convo, members: members(convo), personaMap: personaMap,
                                    typing: engine.isBusy(convo))
                }
                .buttonStyle(PressableRowStyle())
                .contextMenu {
                    Button {
                        withAnimation(Motion.spring) { convo.pinned.toggle() }
                        try? context.save()
                    } label: {
                        Label(convo.pinned ? "取消置顶" : "置顶", systemImage: convo.pinned ? "pin.slash" : "pin")
                    }
                }
                if convo.id != items.last?.id { Hairline(inset: 76) }
            }
            if items.isEmpty && !query.trimmed.isEmpty {
                Text("没有找到「\(query.trimmed)」")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.inkSoft)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .card()
        .animation(Motion.spring, value: items.map(\.id))
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        HStack(spacing: Space.tight) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.inkSoft)
            TextField(placeholder, text: $text)
                .font(.system(size: 15.5))
                .foregroundStyle(Palette.ink)
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.faint)
                }
                .accessibilityLabel("清除")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Space.control)
        .background(Palette.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
    }
}

struct ConversationRow: View {
    let convo: Conversation
    let members: [Persona]
    let personaMap: [UUID: Persona]
    let typing: Bool

    var body: some View {
        TimelineView(.everyMinute) { _ in
            let last = convo.lastVisible(at: .now)
            let unread = convo.hasUnread(at: .now)
            HStack(spacing: Space.item) {
                ConversationAvatar(convo: convo, members: members, size: 50)
                    .overlay(alignment: .topTrailing) {
                        if unread {
                            Circle().fill(Palette.ink).frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(Palette.card, lineWidth: 2))
                                .offset(x: 2, y: -2)
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(convo.displayTitle(members))
                            .font(Typo.serif(17.5, .medium))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        if convo.pinned {
                            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Palette.faint)
                        }
                        Spacer(minLength: Space.tight)
                        if let last {
                            Text(last.createdAt.listStamp).font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
                        }
                    }
                    Text(typing ? "正在输入…" : preview(last))
                        .font(.system(size: 14))
                        .foregroundStyle(typing ? Palette.ink : Palette.inkSoft)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
    }

    private func preview(_ last: Message?) -> String {
        guard let last else { return convo.isGroup ? "\(members.count) 位成员" : (members.first?.bio ?? "") }
        let body: String = switch last.kind {
        case .images: "[图片]"
        case .file: "[文件]"
        case .sticker: "[表情]"
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
