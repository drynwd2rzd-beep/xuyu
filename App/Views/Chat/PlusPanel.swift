import SwiftUI
import SwiftData
import Photos
import PhotosUI
import UIKit

struct PlusPanel: View {
    let isGroup: Bool
    let onPhotos: ([Data]) -> Void
    let onCamera: () -> Void
    let onLibrary: () -> Void
    let onFile: () -> Void
    let onNote: () -> Void
    let onMention: () -> Void
    /// 语音通话、一起听、一起读（只有单聊有）
    var onCall: (() -> Void)? = nil
    var onListen: (() -> Void)? = nil
    var onRead: (() -> Void)? = nil

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
                if let onCall { tile("phone", "语音通话", onCall) }
                if let onListen { tile("music.note", "一起听", onListen) }
                if let onRead { tile("book", "一起读", onRead) }
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

struct RecentThumb: View {
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
