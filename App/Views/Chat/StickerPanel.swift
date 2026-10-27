import SwiftUI
import SwiftData
import Photos
import PhotosUI
import UIKit

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
    @State private var creating = false
    @State private var nameDraft = ""
    @State private var renaming: Category?
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
            .prefix(8).map { $0 }
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
        .alert("新建表情包", isPresented: $creating) {
            TextField("名字，比如：猫猫", text: $nameDraft)
            Button("取消", role: .cancel) { nameDraft = "" }
            Button("新建") { createPack() }
        }
        .alert("重命名分类", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("新名字", text: $nameDraft)
            Button("取消", role: .cancel) { nameDraft = "" }
            Button("好") { rename() }
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
            Button { creating = true } label: {
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
        if section.kind == .recent {
            Button(role: .destructive) { clearRecent() } label: { Label("清空最近使用", systemImage: "clock.arrow.circlepath") }
        } else {
            Button { nameDraft = section.name; renaming = section } label: { Label("重命名", systemImage: "pencil") }
            Button(role: .destructive) { delete(section) } label: { Label("删除分类", systemImage: "trash") }
        }
    }

    private func clearRecent() {
        withAnimation(Motion.spring) {
            for s in stickers where s.lastUsedAt != nil { s.lastUsedAt = nil }
            current = categories.first?.id
        }
        try? context.save()
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
                stickerGrid(recent, addTo: nil, inRecent: true)
            case .pack(let p):
                stickerGrid(stickers.filter { $0.pack == p }, addTo: p)
            }
        }
    }

    private func stickerGrid(_ items: [Sticker], addTo pack: String?, inRecent: Bool = false) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.tight), count: 4), spacing: Space.tight) {
            ForEach(items) { s in
                Button {
                    withAnimation(Motion.pressIn) { bounce = s.id }
                    onSticker(s)
                    Task {
                        try? await Task.sleep(for: .milliseconds(140))
                        withAnimation(Motion.pressOut) { bounce = nil }
                    }
                } label: {
                    Group {
                        if let image = cachedImage(s.data, key: s.id.uuidString) {
                            Image(uiImage: image).resizable().scaledToFit().padding(6)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 74)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    .scaleEffect(bounce == s.id ? 0.86 : 1)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if inRecent {
                        Button {
                            withAnimation(Motion.spring) { s.lastUsedAt = nil }
                            try? context.save()
                        } label: { Label("从最近使用中移除", systemImage: "clock.badge.xmark") }
                    }
                    Button(role: .destructive) {
                        withAnimation(Motion.spring) { context.delete(s) }
                        try? context.save()
                    } label: { Label("删除表情", systemImage: "trash") }
                }
            }
            if let pack {
                addCell(height: 74) {
                    addingTo = pack
                    showPicker = true
                }
            }
        }
    }

    /// 每个表情包最后的「+」：往这个包里加
    private func addCell(height: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.faint)
                .frame(maxWidth: .infinity).frame(height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel("添加")
    }

    // MARK: 动作

    private func addStickers(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let pack = addingTo ?? packs.first ?? "表情"
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let png = ImageUtil.sticker(data) {
                    context.insert(Sticker(pack: pack, data: png))
                }
            }
            try? context.save()
            pickerItems = []
            addingTo = nil
            withAnimation(Motion.spring) { current = "pack:\(pack)" }
        }
    }

    private func createPack() {
        let name = nameDraft.trimmed
        nameDraft = ""
        guard !name.isEmpty, !packs.contains(name) else { return }
        extraPacks = (extraPacks.isEmpty ? "" : extraPacks + "\n") + name
        withAnimation(Motion.spring) { current = "pack:\(name)" }
    }

    private func rename() {
        let name = nameDraft.trimmed
        nameDraft = ""
        guard !name.isEmpty, let section = renaming else { return }
        switch section.kind {
        case .recent: break
        case .pack(let old):
            for s in stickers where s.pack == old { s.pack = name }
            extraPacks = extraPacks.split(separator: "\n").map { $0 == old ? name : String($0) }.joined(separator: "\n")
            try? context.save()
        }
    }

    private func delete(_ section: Category) {
        withAnimation(Motion.spring) {
            switch section.kind {
            case .recent: break
            case .pack(let p):
                for s in stickers where s.pack == p { context.delete(s) }
                extraPacks = extraPacks.split(separator: "\n").filter { $0 != p }.joined(separator: "\n")
                try? context.save()
            }
            current = categories.first?.id
        }
    }
}
