import SwiftUI
import SwiftData
import PhotosUI

/// 表情面板：和键盘一样高。上面一排分类（最近使用、各个图片表情包，最右边 + 新建表情包）；
/// 下面每个分类一页，左右滑动切换
struct StickerPanel: View {
    let onSticker: (Sticker) -> Void
    @Binding var atTop: Bool

    @Environment(\.modelContext) private var context
    @Query(sort: \Sticker.createdAt) private var stickers: [Sticker]
    @AppStorage(Prefs.stickerPackOrder) private var extraPacks = ""
    @State private var current: String?
    @State private var bounce: UUID?
    @State private var addingTo: String?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var naming: Naming?
    @Namespace private var tabNS

    /// 一个分类：最近使用 / 某个图片表情包
    struct Category: Identifiable, Equatable {
        enum Kind: Equatable { case recent, pack(String) }
        let kind: Kind
        let name: String
        var id: String {
            switch kind {
            case .recent: "recent"
            case .pack(let p): "pack:\(p)"
            }
        }
    }

    /// 正在起名字：新建表情包，或者给某个表情包改名
    enum Naming: Identifiable {
        case create
        case rename(String)
        var id: String {
            switch self {
            case .create: "create"
            case .rename(let p): "rename:\(p)"
            }
        }
    }

    private var packs: [String] {
        var seen: [String] = []
        for s in stickers where !seen.contains(s.pack) { seen.append(s.pack) }
        // 新建了但还没放表情的空包也显示
        for p in extraPacks.split(separator: "\n").map(String.init) where !seen.contains(p) { seen.append(p) }
        return seen.isEmpty ? ["表情"] : seen
    }

    private var recent: [Sticker] {
        stickers.filter { $0.lastUsedAt != nil }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            .prefix(12).map { $0 }
    }

    private var categories: [Category] {
        var list: [Category] = []
        if !recent.isEmpty { list.append(Category(kind: .recent, name: "最近使用")) }
        list += packs.map { Category(kind: .pack($0), name: $0) }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.horizontal, Space.item)
                .padding(.top, Space.tight)
                .padding(.bottom, 6)
            content
        }
        .sensoryFeedback(.selection, trigger: current)
        .onAppear { if current == nil { current = categories.first?.id } }
        .photosPicker(isPresented: $showPicker, selection: $pickerItems, maxSelectionCount: 20, matching: .images)
        .onChange(of: pickerItems) { _, items in addStickers(items) }
        // 起名字用一张从下面升起的小卡片：输入框贴在键盘上方，不会和聊天页的键盘、面板互相挤
        .sheet(item: $naming) { naming in
            switch naming {
            case .create:
                PackNameSheet(title: "新建表情包", action: "新建", name: "") { createPack($0) }
            case .rename(let old):
                PackNameSheet(title: "重命名", action: "好", name: old) { rename(old, to: $0) }
            }
        }
    }

    // MARK: 分类栏

    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(categories) { section in
                            tab(section).id(section.id)
                        }
                    }
                }
                .onChange(of: current) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.spring) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Button { naming = .create } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel("新建表情包")
        }
    }

    private func tab(_ section: Category) -> some View {
        let on = current == section.id
        return Button {
            withAnimation(Motion.spring) { current = section.id }
        } label: {
            Group {
                switch section.kind {
                case .recent:
                    Image(systemName: "clock").font(.system(size: 15))
                case .pack(let p):
                    if let first = stickers.first(where: { $0.pack == p }), let image = cachedImage(first.data, key: first.id.uuidString) {
                        Image(uiImage: image).resizable().scaledToFit().frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "photo").font(.system(size: 14))
                    }
                }
            }
            .foregroundStyle(on ? Palette.ink : Palette.inkSoft)
            .frame(width: 34, height: 34)
            .background {
                if on {
                    Circle().fill(Palette.fill).matchedGeometryEffect(id: "tab", in: tabNS)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.name)
        // 长按上面的分类图标也能改名、删除（比长按小标题好按）
        .contextMenu { categoryMenu(section) }
    }

    @ViewBuilder
    private func categoryMenu(_ section: Category) -> some View {
        switch section.kind {
        case .recent:
            Button(role: .destructive) { clearRecent() } label: { Label("清空最近使用", systemImage: "clock.arrow.circlepath") }
        case .pack(let p):
            Button { naming = .rename(p) } label: { Label("重命名", systemImage: "pencil") }
            Button(role: .destructive) { delete(pack: p) } label: { Label("删除表情包", systemImage: "trash") }
        }
    }

    // MARK: 内容：每个分类单独一页，左右滑动切换

    private var content: some View {
        TabView(selection: $current) {
            ForEach(categories) { section in
                ScrollView {
                    sectionView(section)
                        .padding(.horizontal, Space.item)
                        .padding(.bottom, Space.section)
                }
                .scrollIndicators(.hidden)
                // 告诉外面这一页是不是在最上面：在最上面再往下拉，就收起面板
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y <= 1 } action: { _, top in
                    if current == section.id { atTop = top }
                }
                .tag(Optional(section.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(maxHeight: .infinity)
        .animation(Motion.spring, value: current)
    }

    private func sectionView(_ section: Category) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(section.name)
                .font(.system(size: 12))
                .foregroundStyle(Palette.inkSoft)
                .padding(.leading, 4)
                .padding(.top, Space.item)
                .contextMenu { categoryMenu(section) }
            switch section.kind {
            case .recent:
                stickerGrid(recent, pack: nil)
            case .pack(let p):
                stickerGrid(stickers.filter { $0.pack == p }, pack: p)
            }
        }
    }

    /// 一页表情：点一下发出去；长按放大看，还能移到别的表情包、删除；表情包最后一格是「+」
    private func stickerGrid(_ items: [Sticker], pack: String?) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.tight), count: 4), spacing: Space.tight) {
            ForEach(items) { s in
                Button { send(s) } label: {
                    stickerImage(s)
                        .padding(6)
                        .frame(maxWidth: .infinity).frame(height: 74)
                        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                        .scaleEffect(bounce == s.id ? 0.86 : 1)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    stickerMenu(s, inRecent: pack == nil)
                } preview: {
                    stickerImage(s).frame(width: 220, height: 220).padding(Space.section)
                }
            }
            if let pack { addCell(to: pack) }
        }
    }

    @ViewBuilder
    private func stickerImage(_ s: Sticker) -> some View {
        if let image = cachedImage(s.data, key: s.id.uuidString) {
            Image(uiImage: image).resizable().scaledToFit()
        }
    }

    @ViewBuilder
    private func stickerMenu(_ s: Sticker, inRecent: Bool) -> some View {
        if inRecent {
            Button {
                withAnimation(Motion.spring) { s.lastUsedAt = nil }
                context.persist()
            } label: { Label("从最近使用中移除", systemImage: "clock.badge.xmark") }
        }
        let others = packs.filter { $0 != s.pack }
        if !others.isEmpty {
            Menu {
                ForEach(others, id: \.self) { p in
                    Button(p) {
                        withAnimation(Motion.spring) { s.pack = p }
                        context.persist()
                    }
                }
            } label: { Label("移到表情包", systemImage: "folder") }
        }
        Button(role: .destructive) {
            withAnimation(Motion.spring) { context.delete(s) }
            context.persist()
        } label: { Label("删除表情", systemImage: "trash") }
    }

    /// 每个表情包最后的「+」：往这个包里加
    private func addCell(to pack: String) -> some View {
        Button {
            addingTo = pack
            showPicker = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.inkSoft)
                .frame(maxWidth: .infinity).frame(height: 74)
                .background(Palette.paper.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                        .strokeBorder(Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel("添加表情")
    }

    // MARK: 动作

    private func send(_ s: Sticker) {
        withAnimation(Motion.pressIn) { bounce = s.id }
        onSticker(s)
        Task {
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(Motion.pressOut) { bounce = nil }
        }
    }

    private func clearRecent() {
        withAnimation(Motion.spring) {
            for s in stickers where s.lastUsedAt != nil { s.lastUsedAt = nil }
            current = categories.first?.id
        }
        context.persist()
    }

    private func addStickers(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let pack = addingTo ?? packs.first ?? "表情"
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let png = ImageUtil.sticker(data) {
                    context.insert(Sticker(pack: pack, data: png))
                }
            }
            context.persist()
            pickerItems = []
            addingTo = nil
            withAnimation(Motion.spring) { current = "pack:\(pack)" }
        }
    }

    /// 新建表情包：建好就切过去，接着打开相册往里加表情
    private func createPack(_ name: String) {
        if !packs.contains(name) {
            extraPacks = (extraPacks.isEmpty ? "" : extraPacks + "\n") + name
        }
        withAnimation(Motion.spring) { current = "pack:\(name)" }
        addingTo = name
        Task {
            // 等起名字的卡片收下去再打开相册
            try? await Task.sleep(for: .milliseconds(450))
            showPicker = true
        }
    }

    private func rename(_ old: String, to name: String) {
        guard name != old else { return }
        for s in stickers where s.pack == old { s.pack = name }
        extraPacks = extraPacks.split(separator: "\n").map { $0 == old ? name : String($0) }.joined(separator: "\n")
        context.persist()
        withAnimation(Motion.spring) { current = "pack:\(name)" }
    }

    private func delete(pack p: String) {
        withAnimation(Motion.spring) {
            for s in stickers where s.pack == p { context.delete(s) }
            extraPacks = extraPacks.split(separator: "\n").filter { $0 != p }.joined(separator: "\n")
            context.persist()
            current = categories.first?.id
        }
    }
}

/// 给表情包起名字（新建、改名共用）：从下面升起的一张小卡片，弹出来就能直接打字
struct PackNameSheet: View {
    let title: String
    let action: String
    @State var name: String
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: Space.section) {
            HStack {
                Button("取消") { dismiss() }
                    .foregroundStyle(Palette.inkSoft)
                Spacer()
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Button(action, action: done)
                    .fontWeight(.semibold)
                    .foregroundStyle(name.trimmed.isEmpty ? Palette.faint : Palette.ink)
                    .disabled(name.trimmed.isEmpty)
            }
            .font(.system(size: 15))
            TextField("名字，比如：猫猫", text: $name)
                .font(.system(size: 16))
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(done)
                .padding(.horizontal, Space.card)
                .frame(height: 48)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
        }
        .padding(.horizontal, Space.page)
        .padding(.top, Space.page)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(150)])
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(Palette.paper)
        .onAppear { focused = true }
    }

    private func done() {
        let n = name.trimmed
        guard !n.isEmpty else { return }
        onDone(n)
        dismiss()
    }
}
