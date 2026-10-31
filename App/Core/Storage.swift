import Foundation
import os

/// 本机小文件的统一存取（DATA-2）：路径、原子写、读坏了怎么办、写不进去怎么办，都只在这里写一遍。
/// - 读：没有这个文件 → 空；文件坏了（解码失败）→ 改名成「原名.broken」留底、记日志，再从空的继续，下次写入不会盖掉它（DATA-6）
/// - 写：一律原子写；写不进去（存储满了）→ 记日志，屏幕上方提示「没能保存」
/// 不放在主线程上：备份在后台读这些文件，拼提示词也不在主线程
enum Storage {
    /// 根目录：平时是 App 自己的 Application Support；测试换成临时目录，不碰真实数据（SHIP-2）
    static var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    // MARK: - 登记表（DATA-7）

    /// 本机的每一个小文件都在这里登记一次。删消息、删角色时怎么清，写在各自的存储旁边，统一由 Cleanup 调用
    enum File: String, CaseIterable {
        /// 世界观（World）
        case world = "world.json"
        /// 心声：消息 ID → 那句话
        case thoughts = "thoughts.json"
        /// 视频卡片：消息 ID → 卡片
        case videoCards = "video-cards.json"
        /// 通话内容：消息 ID → 每一句
        case calls = "calls.json"
        /// 一起听过的歌
        case listened = "listened.json"
        /// 我的头像（备份里单独一项 myAvatar）
        case myAvatar = "me.jpg"
        /// 照片小组件里的照片（不进备份：从相册再选一次就有）
        case widgetPhoto = "widget-photo.jpg"
        /// 一起读的书：每本一个文件夹（备份里只存进度，见 Books.Saved）
        case books = "books"

        /// 原样打包进备份的 files 一栏（文件名 → 内容）
        var inArchiveFiles: Bool {
            switch self {
            case .world, .thoughts, .videoCards, .calls, .listened: true
            case .myAvatar, .widgetPhoto, .books: false
            }
        }
    }

    /// 聊天背景照片的文件名都以它开头（全局一张，每个对话一张），见 WallpaperStore
    static let wallpaperPrefix = "wallpaper"
    /// 数据库升级失败时挪走的旧库，见 XuyuApp.openStore
    static let rescuePrefix = "数据库备份-"

    // MARK: - 路径

    static func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    static func url(_ file: File) -> URL { url(file.rawValue) }

    // MARK: - 读

    /// 读一个 JSON 文件；没有或读坏了都返回 nil（坏文件已改名留底）
    static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = readData(name) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            quarantine(url(name), error)
            return nil
        }
    }

    static func read<T: Decodable>(_ type: T.Type, from file: File) -> T? { read(type, from: file.rawValue) }

    /// 读原始内容；没有这个文件不算错
    static func readData(_ name: String) -> Data? {
        do {
            return try Data(contentsOf: url(name))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            Log.store.error("读 \(name, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - 写

    @discardableResult
    static func write<T: Encodable>(_ value: T, to name: String) -> Bool {
        do {
            return writeData(try JSONEncoder().encode(value), to: name)
        } catch {
            fail(name, error)
            return false
        }
    }

    @discardableResult
    static func write<T: Encodable>(_ value: T, to file: File) -> Bool { write(value, to: file.rawValue) }

    /// 原子写；写不进去时记日志并提示，返回 false
    @discardableResult
    static func writeData(_ data: Data, to name: String) -> Bool {
        let target = url(name)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            return true
        } catch {
            fail(name, error)
            return false
        }
    }

    // MARK: - 删

    /// 删掉一个文件或文件夹；本来就没有不算错
    static func remove(_ name: String) {
        do {
            try FileManager.default.removeItem(at: url(name))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            Log.store.error("删 \(name, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    static func remove(_ file: File) { remove(file.rawValue) }

    /// 根目录下以这个前缀开头的文件（聊天背景照片、旧数据库）
    static func names(prefix: String) -> [String] {
        // 列不出目录时就当没有：调用的一方只是拿来清理
        let all = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return all.filter { $0.hasPrefix(prefix) }
    }

    // MARK: - 存在设置里的 JSON（约定、TA 对你的称呼、声音名字）

    /// 解码失败时把原来的值挪到「键名.broken」留底、记日志，再从空的继续（DATA-6）
    static func decodeDefault<T: Decodable>(_ type: T.Type, key: String, in defaults: UserDefaults = .standard) -> T? {
        guard let raw = defaults.data(forKey: key) ?? defaults.string(forKey: key).map({ Data($0.utf8) }) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: raw)
        } catch {
            defaults.set(defaults.object(forKey: key), forKey: key + ".broken")
            defaults.removeObject(forKey: key)
            Log.store.error("设置 \(key, privacy: .public) 读不出来，已留底：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - 出错

    private static func quarantine(_ file: URL, _ error: Error) {
        let broken = file.appendingPathExtension("broken")
        let fm = FileManager.default
        // 上一次留的坏文件：只留最新的一份
        try? fm.removeItem(at: broken)
        do {
            try fm.moveItem(at: file, to: broken)
        } catch {
            Log.store.error("坏文件 \(file.lastPathComponent, privacy: .public) 没能改名：\(error.localizedDescription, privacy: .public)")
        }
        Log.store.error("\(file.lastPathComponent, privacy: .public) 读不出来，已改名留底：\(error.localizedDescription, privacy: .public)")
    }

    private static func fail(_ name: String, _ error: Error) {
        Log.store.error("写 \(name, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
        Task { @MainActor in SaveAlert.shared.report() }
    }
}
