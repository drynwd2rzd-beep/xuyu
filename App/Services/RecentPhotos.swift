import UIKit
import Photos
import Observation

/// 加号面板里那一排最近的照片：读相册（先问权限）、出缩略图、发送时取原图
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
