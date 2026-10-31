import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import os

/// 备份：把角色、聊天（含图片和文件）、待办、日记、表情、记忆和主要设置打包成一个文件；
/// 可以导出到「文件」、从文件恢复，也可以每天自动备份到电脑。
/// 打包和拆包都在后台做（照片多了以后有几十 MB，放在主线程会让每天第一次打开 App 时卡一下），
/// 恢复时往数据库里写仍在主线程。
/// 这里只负责组装：每种数据怎么转见 Backup+Records，哪些设置进备份见 Prefs.registry，哪些小文件进备份见 Storage.File（DATA-7）
@MainActor
enum Backup {
    nonisolated static let version = 1
    static let lastBackupKey = Prefs.lastBackupAt
    static let autoKey = Prefs.autoBackupToPC

    struct Archive: Codable {
        var version: Int
        var createdAt: Date
        var personas: [PersonaDTO]
        var conversations: [ConversationDTO]
        var todos: [TodoDTO]
        var diaries: [DiaryDTO]
        var stickers: [StickerDTO]
        var moments: [MomentDTO]?
        var album: [AlbumDTO]?
        /// 设置（都存成文字，恢复时按 Prefs.registry 里登记的类型还原）
        var prefs: [String: String]
        var myAvatar: Data?
        /// 不在数据库里、各自存成小文件的：世界观、心声、视频卡片、通话内容、一起听过的歌（文件名 → 内容）
        var files: [String: Data]?
        /// 每个角色的「真人感」设置和关系（存成 plist，保留原来的类型）
        var touches: Data?
        /// 一起读的书：进度、划线、批注、问答（不含正文，重新导入同一本书时接上）
        var books: [Books.Saved]?
    }

    /// 数据库已经换成备份里的了，但有些小文件（世界观、心声、头像…）没能写进去
    struct Incomplete: LocalizedError {
        var errorDescription: String? { String(localized: "有些内容没能恢复，手机存储可能已满。") }
    }

    nonisolated private static var archivedFiles: [Storage.File] { Storage.File.allCases.filter(\.inArchiveFiles) }

    // MARK: 导出

    /// 打包成一个文件：先把还没存的改动存下来，再在后台的数据库连接里取数据、编码
    static func exportData(context: ModelContext) async throws -> Data {
        context.persist()
        let container = context.container
        // 在后台线程上建这个 actor：在主线程上建的话，它的活也会排到主线程上做
        return try await Task.detached(priority: .utility) {
            try await BackupWorker(modelContainer: container).export()
        }.value
    }

    /// 在哪个线程都能跑：后台的 BackupWorker 用它自己的数据库连接调用。读不出来就整个失败，不打一份缺东西的备份
    nonisolated static func export(context: ModelContext) throws -> Data {
        let defaults = UserDefaults.standard
        var prefs: [String: String] = [:]
        for entry in Prefs.backedUp {
            if let value = defaults.object(forKey: entry.key) { prefs[entry.key] = "\(value)" }
        }
        let touches = defaults.dictionaryRepresentation().filter { key, _ in key.hasPrefix(Prefs.humanPrefix) }
        let archive = Archive(
            version: version, createdAt: .now,
            personas: try context.fetch(FetchDescriptor<Persona>()).map { PersonaDTO($0) },
            conversations: try context.fetch(FetchDescriptor<Conversation>()).map { ConversationDTO($0) },
            todos: try context.fetch(FetchDescriptor<TodoItem>()).map { TodoDTO($0) },
            diaries: try context.fetch(FetchDescriptor<DiaryEntry>()).map { DiaryDTO($0) },
            stickers: try context.fetch(FetchDescriptor<Sticker>()).map { StickerDTO($0) },
            moments: try context.fetch(FetchDescriptor<Moment>()).map { MomentDTO($0) },
            album: try context.fetch(FetchDescriptor<AlbumPhoto>()).map { AlbumDTO($0) },
            prefs: prefs,
            myAvatar: ImageFileStore.myAvatar.fileData,
            files: Dictionary(uniqueKeysWithValues: archivedFiles.compactMap { file in
                Storage.readData(file.rawValue).map { (file.rawValue, $0) }
            }),
            touches: try PropertyListSerialization.data(fromPropertyList: touches, format: .binary, options: 0),
            books: Books.savedStates())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(archive)
    }

    static var fileName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return "絮语备份-\(f.string(from: .now)).json"
    }

    // MARK: 恢复（会替换现在 App 里的全部内容）

    /// 文件不对时抛出解码错误，什么都不动；数据库换好了但有小文件没写进去时抛出 Incomplete
    static func restore(_ data: Data, context: ModelContext) async throws {
        // 拆包在后台做；往数据库里写回到主线程
        let archive = try await Task.detached(priority: .userInitiated) { try Backup.decode(data) }.value
        // 先删光再一条条写回：中途出错就整个撤销，现在的内容原样留着（不会被自动保存成「只删了一半」）
        do {
            try replaceAll(with: archive, context: context)
        } catch {
            context.rollback()
            Log.backup.error("恢复备份没能写进数据库，已撤销：\(error.localizedDescription, privacy: .public)")
            throw error
        }

        var complete = true
        let defaults = UserDefaults.standard
        for entry in Prefs.backedUp {
            guard let text = archive.prefs[entry.key], let value = entry.value(from: text) else { continue }
            defaults.set(value, forKey: entry.key)
        }
        if let avatar = archive.myAvatar { complete = ImageFileStore.myAvatar.save(avatar) && complete }
        // 旧备份里没有这些：原来的留着不动
        if let files = archive.files {
            for file in archivedFiles {
                if let data = files[file.rawValue] {
                    complete = Storage.writeData(data, to: file.rawValue) && complete
                } else {
                    Storage.remove(file)
                }
            }
            World.reload()
            Thoughts.shared.reload()
            VideoCards.shared.reload()
            CallLogs.shared.reload()
            ListenTogether.shared.reloadHistory()
        }
        if let books = archive.books { Books.shared.restore(books) }
        if let touches = archive.touches {
            do {
                let saved = try PropertyListSerialization.propertyList(from: touches, format: nil) as? [String: Any] ?? [:]
                for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Prefs.humanPrefix) { defaults.removeObject(forKey: key) }
                for (key, value) in saved { defaults.set(value, forKey: key) }
            } catch {
                Log.backup.error("真人感设置没能恢复：\(error.localizedDescription, privacy: .public)")
                complete = false
            }
        }
        let todos = (try? context.fetch(FetchDescriptor<TodoItem>())) ?? []
        todos.forEach(Reminders.sync)
        if !complete { throw Incomplete() }
    }

    nonisolated private static func decode(_ data: Data) throws -> Archive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Archive.self, from: data)
    }

    private static func replaceAll(with archive: Archive, context: ModelContext) throws {
        try context.delete(model: Attachment.self)
        try context.delete(model: Message.self)
        try context.delete(model: Conversation.self)
        try context.delete(model: Persona.self)
        try context.delete(model: TodoItem.self)
        try context.delete(model: DiaryEntry.self)
        try context.delete(model: Sticker.self)
        try context.delete(model: MomentComment.self)
        try context.delete(model: Moment.self)
        try context.delete(model: AlbumPhoto.self)

        archive.personas.forEach { context.insert($0.make()) }
        archive.conversations.forEach { $0.insert(into: context) }
        archive.todos.forEach { context.insert($0.make()) }
        archive.diaries.forEach { context.insert($0.make()) }
        archive.stickers.forEach { context.insert($0.make()) }
        (archive.album ?? []).forEach { context.insert($0.make()) }
        (archive.moments ?? []).forEach { $0.insert(into: context) }
        try context.save()
    }

    // MARK: 自动备份到电脑（每天一次）

    static func autoBackupIfNeeded(context: ModelContext, relay: RelayClient) async {
        let defaults = UserDefaults.standard
        guard !DemoMode.isOn, defaults.object(forKey: autoKey) as? Bool ?? true, relay.isConnected else { return }
        let now = Date.now.timeIntervalSince1970
        guard now - defaults.double(forKey: lastBackupKey) > Limits.Timing.autoBackup else { return }
        // 刚失败过：隔一阵再试，不要每次回到 App 都把几十 MB 重新打包、重新传一遍
        guard now - defaults.double(forKey: Prefs.backupFailedAt) > Limits.Timing.backupRetry else { return }
        await backupToPC(context: context, relay: relay)
    }

    @discardableResult
    static func backupToPC(context: ModelContext, relay: RelayClient) async -> Bool {
        let defaults = UserDefaults.standard
        let failure: String?
        do {
            let data = try await exportData(context: context)
            failure = await relay.saveBackup(name: fileName, data: data) ? nil : "电脑没有回应"
        } catch {
            Log.backup.error("打包备份出错：\(error.localizedDescription, privacy: .public)")
            failure = "打包备份时出错"
        }
        // 成功：记下时间，清掉上次的失败；没成功：记下时间和原因，设置页「备份与恢复」里能看到
        if let failure {
            defaults.set(Date.now.timeIntervalSince1970, forKey: Prefs.backupFailedAt)
            defaults.set(failure, forKey: Prefs.backupFailReason)
        } else {
            defaults.set(Date.now.timeIntervalSince1970, forKey: lastBackupKey)
            defaults.removeObject(forKey: Prefs.backupFailedAt)
            defaults.removeObject(forKey: Prefs.backupFailReason)
        }
        return failure == nil
    }
}

/// 在后台打包备份：用自己的数据库连接，不占主线程
@ModelActor
actor BackupWorker {
    func export() throws -> Data {
        try Backup.export(context: modelContext)
    }
}

/// 导出备份时交给系统「存储到文件」用
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
