import AVFoundation

/// 复刻用的录音：几段音频、视频里的声音按顺序接成一段，压成 m4a（大小不用管）；超过上限的部分截掉
enum AudioMerge {
    /// 复刻最多用 5 分钟
    static let cloneLimit: Double = 300
    /// 参考录音最多 8 秒
    static let referenceLimit: Double = 7.9

    /// 一段音频或视频有多长（秒）；读不出声音就是 0
    static func duration(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let length = try? await asset.load(.duration) else { return 0 }
        return length.seconds.isFinite ? length.seconds : 0
    }

    static func merge(_ urls: [URL], limit: Double) async throws -> Data {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Voice.Failure.other("读不出这段录音")
        }
        let cap = CMTime(seconds: limit, preferredTimescale: 600)
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let length = try await asset.load(.duration)
            let take = min(length, cap - cursor)
            guard take > .zero else { break }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: take), of: source, at: cursor)
            cursor = cursor + take
        }
        guard cursor.seconds >= 1 else { throw Voice.Failure.other("读不出这段录音") }
        let out = FileManager.default.temporaryDirectory.appending(path: "clone-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: out) }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw Voice.Failure.other("录音转换失败")
        }
        try await export.export(to: out, as: .m4a)
        return try Data(contentsOf: out)
    }

    /// 选进来的文件先拷到临时文件夹（文件 App 给的地址过一会儿就不能读了）
    static func copyIn(_ url: URL) -> URL? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }
}
