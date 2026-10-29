import SwiftUI

/// 聊天记录搜索：关键词高亮，可按照片、文件、想法筛选
struct ChatSearchView: View {
    let convo: Conversation
    let members: [Persona]
    let personaMap: [UUID: Persona]
    /// 关闭；带上要跳转的消息
    let onClose: (UUID?) -> Void

    enum Filter: String, CaseIterable {
        case all = "全部", photo = "照片", file = "文件", note = "想法"
    }

    @State private var query = ""
    @State private var filter: Filter = .all
    @AppStorage(Prefs.recentSearches) private var recentRaw = ""
    @FocusState private var focused: Bool

    private var recents: [String] { recentRaw.split(separator: "\n").map(String.init) }

    /// 撤回的不算：撤回了的话不该还能搜出来
    private var messages: [Message] { convo.visibleMessages().filter { !$0.recalled } }

    private var textHits: [Message] {
        let q = query.trimmed
        let base: [Message] = switch filter {
        // 图片的配文、语音转出来的文字、文件附带的话也能搜到
        case .all: messages.filter { [.text, .note, .images, .voice, .file].contains($0.kind) && !$0.content.isEmpty }
        case .note: messages.filter { $0.kind == .note }
        default: []
        }
        guard !q.isEmpty else { return filter == .note ? base.reversed() : [] }
        return base.filter { $0.content.localizedCaseInsensitiveContains(q) }.reversed()
    }

    private var photos: [Attachment] {
        guard filter == .photo else { return [] }
        return messages.filter { $0.kind == .images }.flatMap(\.sortedAttachments).reversed()
    }

    private var files: [(Message, Attachment)] {
        guard filter == .file else { return [] }
        let q = query.trimmed
        return messages.filter { $0.kind == .file }
            .flatMap { m in m.sortedAttachments.map { (m, $0) } }
            .filter { q.isEmpty || $0.1.fileName.localizedCaseInsensitiveContains(q) }
            .reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SearchField(text: $query, placeholder: "搜索聊天记录")
                    .focused($focused)
                    .onSubmit(remember)
                Button("取消") { onClose(nil) }
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.ink)
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.tight)

            HStack(spacing: Space.tight) {
                ForEach(Filter.allCases, id: \.self) { f in
                    Button { withAnimation(Motion.snappy) { filter = f } } label: {
                        Text(f.rawValue)
                            .font(.system(size: 13, weight: filter == f ? .semibold : .regular))
                            .foregroundStyle(filter == f ? Palette.inkInverse : Palette.ink2)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(filter == f ? Palette.ink : Palette.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: filter == f ? 0 : 0.5))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, Space.page)
            .padding(.vertical, Space.item)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) {
                    if query.trimmed.isEmpty && filter == .all {
                        recentSection
                    }
                    if !textHits.isEmpty { messagesSection }
                    if !photos.isEmpty { photosSection }
                    if !files.isEmpty { filesSection }
                    if showEmpty {
                        VStack(spacing: Space.tight) {
                            Image(systemName: "magnifyingglass").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.faint)
                            Text("没有找到相关内容").font(.system(size: 14)).foregroundStyle(Palette.inkSoft)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                }
                .padding(.horizontal, Space.page)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .background(Palette.paper.ignoresSafeArea())
        .onAppear { focused = true }
        .sensoryFeedback(.selection, trigger: filter)
    }

    private var showEmpty: Bool {
        let searched = !query.trimmed.isEmpty || filter != .all
        return searched && textHits.isEmpty && photos.isEmpty && files.isEmpty
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !recents.isEmpty {
                SectionLabel(text: "最近搜索")
                FlowRow(items: recents) { word in
                    Button { query = word } label: {
                        Text(word)
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Palette.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 不是普通文字时，名字后面标一下是哪种（图片配文、语音转的文字……）
    private func kindTag(_ m: Message) -> String {
        switch m.kind {
        case .images: String(localized: " · 图片")
        case .voice: String(localized: " · 语音")
        case .file: String(localized: " · 文件")
        default: ""
        }
    }

    private var messagesSection: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            SectionLabel(text: "消息 · \(textHits.count) 条")
            VStack(spacing: 0) {
                ForEach(textHits) { m in
                    Button {
                        remember()
                        onClose(m.id)
                    } label: {
                        HStack(alignment: .top, spacing: Space.item) {
                            if m.role == .user { UserAvatar(size: 30) } else { AvatarView(persona: m.personaID.flatMap { personaMap[$0] }, size: 30) }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text((m.role == .user ? "你" : (m.personaID.flatMap { personaMap[$0]?.name } ?? "AI")) + kindTag(m))
                                    Spacer()
                                    Text(m.createdAt.listStamp)
                                }
                                .font(.system(size: Typo.secondary))
                                .foregroundStyle(Palette.inkSoft)
                                Text(highlighted(m.content))
                                    .font(.system(size: 15))
                                    .lineSpacing(3)
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, Space.item)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableRowStyle())
                    if m.id != textHits.last?.id { Hairline(inset: 56) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .card()
        }
    }

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            SectionLabel(text: "照片 · \(photos.count) 张")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(photos) { a in
                    Group {
                        if let image = cachedImage(a.data, key: a.id.uuidString) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Palette.fill
                        }
                    }
                    .frame(height: 112)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    .onTapGesture { onClose(a.message?.id) }
                }
            }
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            SectionLabel(text: "文件 · \(files.count) 个")
            ForEach(Array(files.enumerated()), id: \.offset) { _, pair in
                Button { onClose(pair.0.id) } label: {
                    FileCard(name: pair.1.fileName, size: pair.1.data.count, time: pair.0.createdAt.listStamp)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        let q = query.trimmed
        var flat = text.replacingOccurrences(of: "\n", with: " ")
        if !q.isEmpty, let range = flat.range(of: q, options: .caseInsensitive) {
            // 关键词前保留一小段上下文
            let start = flat.index(range.lowerBound, offsetBy: -12, limitedBy: flat.startIndex) ?? flat.startIndex
            if start > flat.startIndex { flat = "…" + flat[start...] }
        }
        var attributed = AttributedString(flat)
        if !q.isEmpty {
            var searchStart = attributed.startIndex
            while let r = attributed[searchStart...].range(of: q, options: .caseInsensitive) {
                attributed[r].backgroundColor = Palette.highlight
                searchStart = r.upperBound
            }
        }
        return attributed
    }

    private func remember() {
        let q = query.trimmed
        guard !q.isEmpty else { return }
        let list = [q] + recents.filter { $0 != q }
        recentRaw = list.prefix(8).joined(separator: "\n")
    }
}

/// 自动换行的一排标签
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        FlowLayout(spacing: Space.tight) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
