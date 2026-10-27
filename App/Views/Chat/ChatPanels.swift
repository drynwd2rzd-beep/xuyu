import SwiftUI
import SwiftData
import Photos
import PhotosUI
import UIKit

// MARK: - 「+」面板

struct PlusPanel: View {
    let isGroup: Bool
    let onPhotos: ([Data]) -> Void
    let onCamera: () -> Void
    let onLibrary: () -> Void
    let onFile: () -> Void
    let onNote: () -> Void
    let onMention: () -> Void

    @State private var recent = RecentPhotos()
    @State private var picked: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            if !recent.assets.isEmpty {
                HStack {
                    Text("最近照片").font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
                    Spacer()
                    if !picked.isEmpty {
                        Button {
                            Task {
                                let datas = await recent.data(for: picked)
                                picked = []
                                onPhotos(datas)
                            }
                        } label: {
                            Text("选好 \(picked.count) 张")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.inkInverse)
                                .padding(.horizontal, Space.item)
                                .frame(height: 28)
                                .background(Palette.ink, in: Capsule())
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 2)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.tight) {
                        ForEach(recent.assets, id: \.localIdentifier) { asset in
                            RecentThumb(asset: asset, recent: recent, selected: picked.contains(asset.localIdentifier)) {
                                withAnimation(Motion.snappy) {
                                    if let i = picked.firstIndex(of: asset.localIdentifier) { picked.remove(at: i) } else { picked.append(asset.localIdentifier) }
                                }
                            }
                        }
                    }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.item), count: 4), spacing: Space.section) {
                tile("camera", "相机", onCamera)
                tile("photo.on.rectangle", "照片", onLibrary)
                tile("doc", "文件", onFile)
                tile("pencil.line", "写想法", onNote)
                if isGroup { tile("at", "成员", onMention) }
            }
        }
        .padding(.horizontal, Space.page)
        .padding(.top, Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await recent.load() }
        .animation(Motion.spring, value: picked)
    }

    private func tile(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 21))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 60, height: 60)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                Text(label).font(.system(size: 12)).foregroundStyle(Palette.ink2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

private struct RecentThumb: View {
    let asset: PHAsset
    let recent: RecentPhotos
    let selected: Bool
    let onTap: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image { Image(uiImage: image).resizable().scaledToFill() } else { Palette.fill }
                }
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                Circle()
                    .fill(selected ? Palette.ink : Color.black.opacity(0.15))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .overlay { if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                    .frame(width: 20, height: 20)
                    .padding(6)
            }
            .scaleEffect(selected ? 0.94 : 1)
        }
        .buttonStyle(.plain)
        .task { image = await recent.thumbnail(asset) }
    }
}

@MainActor
@Observable
final class RecentPhotos {
    private(set) var assets: [PHAsset] = []
    @ObservationIgnored private let manager = PHCachingImageManager()

    func load() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 16
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var list: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
    }

    func thumbnail(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { c in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            manager.requestImage(for: asset, targetSize: CGSize(width: 200, height: 200), contentMode: .aspectFill, options: options) { image, _ in
                c.resume(returning: image)
            }
        }
    }

    func data(for ids: [String]) async -> [Data] {
        var out: [Data] = []
        for id in ids {
            guard let asset = assets.first(where: { $0.localIdentifier == id }) else { continue }
            let data: Data? = await withCheckedContinuation { c in
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                    c.resume(returning: data)
                }
            }
            if let data { out.append(data) }
        }
        return out
    }
}

// MARK: - 表情面板

/// 颜文字分类：名字 + 一组颜文字，存在本机，可以自己新建、改名、删除、往里加
struct KaomojiGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var items: [String]
}

enum KaomojiStore {
    static let key = "kaomojiGroups"

    /// 默认不带颜文字分类；想要的话在表情面板的「+」里自己建
    static let defaults: [KaomojiGroup] = []

    static func decode(_ data: Data) -> [KaomojiGroup] {
        (try? JSONDecoder().decode([KaomojiGroup].self, from: data)) ?? defaults
    }

    static func encode(_ groups: [KaomojiGroup]) -> Data {
        (try? JSONEncoder().encode(groups)) ?? Data()
    }
}

/// 表情面板：和键盘一样高。上面一排分类（最近、图片表情包、颜文字分类，最右边 + 新建分类）；
/// 下面所有分类连成一条长列表，点分类会顺滑地滚过去，手动滑动时上面选中的分类也跟着变
struct StickerPanel: View {
    let onKaomoji: (String) -> Void
    let onSticker: (Sticker) -> Void
    @Binding var atTop: Bool

    @Environment(\.modelContext) private var context
    @Query(sort: \Sticker.createdAt) private var stickers: [Sticker]
    @AppStorage(KaomojiStore.key) private var groupsData = Data()
    @AppStorage("stickerPackOrder") private var extraPacks = ""
    @State private var current: String?
    @State private var bounce: UUID?
    @State private var addingTo: String?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var newKind: NewKind?
    @State private var nameDraft = ""
    @State private var kaomojiTarget: UUID?
    @State private var kaomojiDraft = ""
    @State private var renaming: Category?
    @Namespace private var tabNS

    enum NewKind: Identifiable { case pack, kaomoji; var id: Self { self } }

    /// 一个分类：最近 / 图片表情包 / 颜文字分类
    struct Category: Identifiable, Equatable {
        enum Kind: Equatable { case recent, pack(String), kaomoji(UUID) }
        let kind: Kind
        let name: String
        var id: String {
            switch kind {
            case .recent: "recent"
            case .pack(let p): "pack:\(p)"
            case .kaomoji(let id): "kao:\(id.uuidString)"
            }
        }
    }

    private var groups: [KaomojiGroup] { groupsData.isEmpty ? KaomojiStore.defaults : KaomojiStore.decode(groupsData) }

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
        list += groups.map { Category(kind: .kaomoji($0.id), name: $0.name) }
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
        .alert(newKind == .pack ? "新建表情包" : "新建颜文字分类",
               isPresented: Binding(get: { newKind != nil }, set: { if !$0 { newKind = nil } })) {
            TextField("名字，比如：猫猫", text: $nameDraft)
            Button("取消", role: .cancel) { nameDraft = "" }
            Button("新建") { createSection() }
        }
        .alert("添加颜文字", isPresented: Binding(get: { kaomojiTarget != nil }, set: { if !$0 { kaomojiTarget = nil } })) {
            TextField("例如 (｡•̀ᴗ-)✧", text: $kaomojiDraft)
            Button("取消", role: .cancel) { kaomojiDraft = "" }
            Button("添加") { addKaomoji() }
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
            Menu {
                Button { newKind = .pack } label: { Label("图片表情包", systemImage: "photo.on.rectangle") }
                Button { newKind = .kaomoji } label: { Label("颜文字分类", systemImage: "textformat") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("新建分类")
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
                case .kaomoji:
                    Text(String(section.name.prefix(1))).font(.system(size: 14, weight: .medium))
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
            case .kaomoji(let id):
                kaomojiGrid(groups.first { $0.id == id }?.items ?? [], group: id)
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

    private func kaomojiGrid(_ items: [String], group: UUID) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, k in
                Button { onKaomoji(k) } label: {
                    Text(k).font(.system(size: 12.5)).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .padding(.horizontal, 2)
                }
                .buttonStyle(ScaleButtonStyle())
                .contextMenu {
                    Button(role: .destructive) { removeKaomoji(at: index, in: group) } label: { Label("删除", systemImage: "trash") }
                }
            }
            addCell(height: 40) { kaomojiTarget = group }
        }
    }

    /// 每个分类最后的「+」：往这个分类里加
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

    private func createSection() {
        let name = nameDraft.trimmed
        nameDraft = ""
        guard !name.isEmpty, let kind = newKind else { return }
        switch kind {
        case .pack:
            guard !packs.contains(name) else { return }
            extraPacks = (extraPacks.isEmpty ? "" : extraPacks + "\n") + name
            withAnimation(Motion.spring) { current = "pack:\(name)" }
        case .kaomoji:
            let group = KaomojiGroup(name: name, items: [])
            groupsData = KaomojiStore.encode(groups + [group])
            withAnimation(Motion.spring) { current = "kao:\(group.id.uuidString)" }
        }
    }

    private func addKaomoji() {
        let text = kaomojiDraft.trimmed
        kaomojiDraft = ""
        guard !text.isEmpty, let target = kaomojiTarget else { return }
        var list = groups
        if let i = list.firstIndex(where: { $0.id == target }) { list[i].items.append(text) }
        withAnimation(Motion.spring) { groupsData = KaomojiStore.encode(list) }
    }

    private func removeKaomoji(at index: Int, in group: UUID) {
        var list = groups
        guard let i = list.firstIndex(where: { $0.id == group }), list[i].items.indices.contains(index) else { return }
        list[i].items.remove(at: index)
        withAnimation(Motion.spring) { groupsData = KaomojiStore.encode(list) }
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
        case .kaomoji(let id):
            var list = groups
            if let i = list.firstIndex(where: { $0.id == id }) { list[i].name = name }
            groupsData = KaomojiStore.encode(list)
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
            case .kaomoji(let id):
                groupsData = KaomojiStore.encode(groups.filter { $0.id != id })
            }
            current = categories.first?.id
        }
    }
}

// MARK: - 相机

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onImage(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
