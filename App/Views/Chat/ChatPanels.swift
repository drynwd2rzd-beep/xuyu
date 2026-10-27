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
        VStack(alignment: .leading, spacing: Space.item) {
            if !recent.assets.isEmpty {
                HStack {
                    Text("最近照片").font(Typo.serif(13)).foregroundStyle(Palette.inkSoft)
                    Spacer()
                    if !picked.isEmpty {
                        Button {
                            Task {
                                let datas = await recent.data(for: picked)
                                picked = []
                                onPhotos(datas)
                            }
                        } label: {
                            Text("发送 \(picked.count) 张")
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
            HStack(spacing: Space.tight) {
                tile("camera", "相机", onCamera)
                tile("photo.on.rectangle", "照片", onLibrary)
                tile("doc", "文件", onFile)
                tile("pencil.line", "写想法", onNote)
                if isGroup { tile("at", "成员", onMention) }
            }
        }
        .padding(Space.item)
        .background(Palette.card.opacity(0.94), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
        .task { await recent.load() }
        .animation(Motion.spring, value: picked)
    }

    private func tile(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 52, height: 52)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
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
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
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

struct StickerPanel: View {
    let onKaomoji: (String) -> Void
    let onSticker: (Sticker) -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \Sticker.createdAt) private var stickers: [Sticker]
    @State private var tab = "recent"
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var bounce: UUID?
    @Namespace private var tabNS

    static let kaomoji = ["(≧▽≦)", "(｡•̀ᴗ-)✧", "(๑•̀ㅂ•́)و✧", "(っ˘ω˘ς)", "(´；ω；`)", "(｀・ω・´)", "╮(╯▽╰)╭", "(*/ω＼*)",
                          "ヾ(≧▽≦*)o", "(ง •_•)ง", "( ˘ᵕ˘ )", "(｡•́︿•̀｡)", "(*^▽^*)", "(＾▽＾)", "(・∀・)", "(￣▽￣)~*"]

    private var packs: [String] {
        var seen: [String] = []
        for s in stickers where !seen.contains(s.pack) { seen.append(s.pack) }
        return seen.isEmpty ? ["我的"] : seen
    }

    private var current: [Sticker] {
        if tab == "recent" {
            return stickers.filter { $0.lastUsedAt != nil }.sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }.prefix(16).map { $0 }
        }
        return stickers.filter { $0.pack == tab }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                tabButton(id: "recent") { Image(systemName: "clock").font(.system(size: 15)) }
                tabButton(id: "kao") { Text("(･ω･)").font(.system(size: 12.5)) }
                ForEach(packs, id: \.self) { pack in
                    tabButton(id: pack) { Text(pack).font(.system(size: 13)) }
                }
                Spacer()
                Button { showPicker = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink2)
                        .frame(width: 34, height: 34)
                        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(Palette.faint, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
                .accessibilityLabel("添加表情")
            }
            ScrollView {
                Group {
                if tab == "kao" {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(Self.kaomoji, id: \.self) { k in
                            Button { onKaomoji(k) } label: {
                                Text(k).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1)
                                    .frame(maxWidth: .infinity).frame(height: 40)
                                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }
                    }
                } else if current.isEmpty {
                    VStack(spacing: 6) {
                        StickerGlyph(size: 30).opacity(0.35)
                        Text(tab == "recent" ? "还没有用过表情" : "点右上角的 + 从相册添加").font(.system(size: 13)).foregroundStyle(Palette.inkSoft)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.tight), count: 4), spacing: Space.tight) {
                        ForEach(current) { s in
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
                                Button(role: .destructive) {
                                    context.delete(s)
                                    try? context.save()
                                } label: { Label("删除表情", systemImage: "trash") }
                            }
                        }
                    }
                }
                }
                .padding(.bottom, 4)
                .id(tab)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            .scrollIndicators(.hidden)
            // 面板高度固定，切换分类或打开时不会挤压聊天内容
            .frame(height: 232)
        }
        .padding(10)
        .background(Palette.card.opacity(0.94), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
        .animation(Motion.spring, value: tab)
        .sensoryFeedback(.selection, trigger: tab)
        .photosPicker(isPresented: $showPicker, selection: $pickerItems, maxSelectionCount: 20, matching: .images)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            let pack = (tab == "recent" || tab == "kao") ? (packs.first ?? "我的") : tab
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let png = ImageUtil.sticker(data) {
                        context.insert(Sticker(pack: pack, data: png))
                    }
                }
                try? context.save()
                pickerItems = []
                tab = pack
            }
        }
    }

    private func tabButton<L: View>(id: String, @ViewBuilder label: () -> L) -> some View {
        Button {
            withAnimation(Motion.spring) { tab = id }
        } label: {
            label()
                .foregroundStyle(tab == id ? Palette.ink : Palette.inkSoft)
                .padding(.horizontal, 10)
                .frame(minWidth: 40, minHeight: 34)
                .background {
                    if tab == id {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .fill(Palette.fill)
                            .matchedGeometryEffect(id: "tab", in: tabNS)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
