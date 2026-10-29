import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 备份：把角色、聊天（含图片和文件）、待办、日记、表情、记忆和主要设置打包成一个文件；
/// 可以导出到「文件」、从文件恢复，也可以每天自动备份到电脑。
/// 打包和拆包都在后台做（照片多了以后有几十 MB，放在主线程会让每天第一次打开 App 时卡一下），
/// 恢复时往数据库里写仍在主线程
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
        var prefs: [String: String]
        var myAvatar: Data?
        /// 不在数据库里、各自存成小文件的：世界观、心声、视频卡片、通话内容、一起听过的歌（文件名 → 内容）
        var files: [String: Data]?
        /// 每个角色的「真人感」设置和关系、天气设置（存成 plist）
        var touches: Data?
    }

    struct PersonaDTO: Codable {
        var id: UUID, name: String, bio: String, systemPrompt: String, tint: Int, avatarData: Data?
        var engineRaw: String, model: String, effort: String, canWork: Bool
        var proactive: Bool, proactiveFreq: Int, sortIndex: Int, createdAt: Date
        var followUp: Int?
        var voiceID: String?, voiceName: String?, voiceFreq: Int?, language: String?, autoTranslate: Bool?
        var voiceProvider: String?, voiceModel: String?
        var voiceSpeed: Double?, voiceVolume: Double?, voicePitch: Int?, voiceEmotion: String?
        var voiceStyle: String?
        var momentsFreq: Int?, momentsMutual: Bool?
    }

    struct ConversationDTO: Codable {
        var id: UUID, title: String, isGroup: Bool, memberIDs: [UUID], pinned: Bool, draft: String
        var createdAt: Date, updatedAt: Date, lastReadAt: Date, memory: String, memoryUntil: Date, discussRounds: Int
        var messages: [MessageDTO]
    }

    struct MessageDTO: Codable {
        var id: UUID, roleRaw: String, kindRaw: String, content: String, reasoning: String, personaID: UUID?
        var statusRaw: String, errorText: String?, modelLabel: String, steps: String, quote: String
        var isProactive: Bool, readAt: Date?, recalled: Bool, createdAt: Date
        var quoteID: UUID?
        var translation: String?
        var momentID: UUID?
        var attachments: [AttachmentDTO]
    }

    struct AttachmentDTO: Codable {
        var kindRaw: String, fileName: String, order: Int, data: Data
    }

    struct TodoDTO: Codable {
        var id: UUID, title: String, notes: String, isDone: Bool, dueDate: Date?, hasTime: Bool
        var remind: Bool, remindLead: Int, createdAt: Date, completedAt: Date?
    }

    struct DiaryDTO: Codable {
        var id: UUID, day: Date, authorRaw: String, text: String, mood: String, personaID: UUID?, createdAt: Date
        var reply: String, replyPersonaID: UUID?, repliedText: String
    }

    struct MomentDTO: Codable {
        var id: UUID, personaID: UUID?, text: String, mood: String, photoIDs: [UUID], voice: Data?
        var likedBy: [UUID], likedByMe: Bool, reacted: Bool, createdAt: Date
        var comments: [CommentDTO]
    }

    struct CommentDTO: Codable {
        var id: UUID, personaID: UUID?, replyTo: UUID?, replyToMe: Bool, text: String, createdAt: Date
    }

    struct AlbumDTO: Codable {
        var id: UUID, personaID: UUID?, data: Data, caption: String, createdAt: Date
    }

    struct StickerDTO: Codable {
        var id: UUID, pack: String, data: Data, createdAt: Date, lastUsedAt: Date?
    }

    /// 一起备份的设置
    nonisolated private static let prefKeys = [Prefs.nickname, Prefs.appearance, Prefs.wallpaper, Prefs.defaultClaudeModel, Prefs.defaultCodexModel,
                                   Prefs.defaultClaudeEffort, Prefs.defaultCodexEffort, Prefs.inAppBanner, Prefs.todoReminders,
                                   Prefs.diaryReminder, Prefs.quietStart, Prefs.quietEnd, Prefs.homeWidgets, Prefs.showEngineLogo,
                                   Prefs.diaryWriter, Prefs.stickerPackOrder, Prefs.appointments, Prefs.minimaxRegion,
                                   Prefs.voiceNames]

    nonisolated private static let localFiles = ["world.json", "thoughts.json", "video-cards.json", "calls.json", "listened.json"]
    nonisolated private static let touchPrefixes = ["human.", "weather.enabled", "weather.city"]

    nonisolated private static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

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

    /// 在哪个线程都能跑：后台的 BackupWorker 用它自己的数据库连接调用
    nonisolated static func export(context: ModelContext) throws -> Data {
        let personas = (try? context.fetch(FetchDescriptor<Persona>())) ?? []
        let convos = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        let todos = (try? context.fetch(FetchDescriptor<TodoItem>())) ?? []
        let diaries = (try? context.fetch(FetchDescriptor<DiaryEntry>())) ?? []
        let stickers = (try? context.fetch(FetchDescriptor<Sticker>())) ?? []
        let moments = (try? context.fetch(FetchDescriptor<Moment>())) ?? []
        let album = (try? context.fetch(FetchDescriptor<AlbumPhoto>())) ?? []
        let defaults = UserDefaults.standard
        var prefs: [String: String] = [:]
        for key in prefKeys {
            if let value = defaults.object(forKey: key) { prefs[key] = "\(value)" }
        }
        let archive = Archive(
            version: version, createdAt: .now,
            personas: personas.map {
                PersonaDTO(id: $0.id, name: $0.name, bio: $0.bio, systemPrompt: $0.systemPrompt, tint: $0.tint, avatarData: $0.avatarData,
                           engineRaw: $0.engineRaw, model: $0.model, effort: $0.effort, canWork: $0.canWork, proactive: $0.proactive,
                           proactiveFreq: $0.proactiveFreq, sortIndex: $0.sortIndex, createdAt: $0.createdAt, followUp: $0.followUp,
                           voiceID: $0.voiceID, voiceName: $0.voiceName, voiceFreq: $0.voiceFreq, language: $0.language, autoTranslate: $0.autoTranslate,
                           voiceProvider: $0.voiceProvider, voiceModel: $0.voiceModel,
                           voiceSpeed: $0.voiceSpeed, voiceVolume: $0.voiceVolume, voicePitch: $0.voicePitch, voiceEmotion: $0.voiceEmotion,
                           voiceStyle: $0.voiceStyle, momentsFreq: $0.momentsFreq, momentsMutual: $0.momentsMutual)
            },
            conversations: convos.map { c in
                ConversationDTO(id: c.id, title: c.title, isGroup: c.isGroup, memberIDs: c.memberIDs, pinned: c.pinned, draft: c.draft,
                                createdAt: c.createdAt, updatedAt: c.updatedAt, lastReadAt: c.lastReadAt, memory: c.memory,
                                memoryUntil: c.memoryUntil, discussRounds: c.discussRounds,
                                messages: (c.messages ?? []).filter { $0.status != .streaming }.map { m in
                                    MessageDTO(id: m.id, roleRaw: m.roleRaw, kindRaw: m.kindRaw, content: m.content, reasoning: m.reasoning,
                                               personaID: m.personaID, statusRaw: m.statusRaw, errorText: m.errorText, modelLabel: m.modelLabel,
                                               steps: m.steps, quote: m.quote, isProactive: m.isProactive, readAt: m.readAt,
                                               recalled: m.recalled, createdAt: m.createdAt, quoteID: m.quoteID, translation: m.translation,
                                               momentID: m.momentID,
                                               attachments: m.sortedAttachments.map {
                                                   AttachmentDTO(kindRaw: $0.kindRaw, fileName: $0.fileName, order: $0.order, data: $0.data)
                                               })
                                })
            },
            todos: todos.map {
                TodoDTO(id: $0.id, title: $0.title, notes: $0.notes, isDone: $0.isDone, dueDate: $0.dueDate, hasTime: $0.hasTime,
                        remind: $0.remind, remindLead: $0.remindLead, createdAt: $0.createdAt, completedAt: $0.completedAt)
            },
            diaries: diaries.map {
                DiaryDTO(id: $0.id, day: $0.day, authorRaw: $0.authorRaw, text: $0.text, mood: $0.mood, personaID: $0.personaID,
                         createdAt: $0.createdAt, reply: $0.reply, replyPersonaID: $0.replyPersonaID, repliedText: $0.repliedText)
            },
            stickers: stickers.map { StickerDTO(id: $0.id, pack: $0.pack, data: $0.data, createdAt: $0.createdAt, lastUsedAt: $0.lastUsedAt) },
            moments: moments.map { m in
                MomentDTO(id: m.id, personaID: m.personaID, text: m.text, mood: m.mood, photoIDs: m.photoIDs, voice: m.voice,
                          likedBy: m.likedBy, likedByMe: m.likedByMe, reacted: m.reacted, createdAt: m.createdAt,
                          comments: (m.comments ?? []).map {
                              CommentDTO(id: $0.id, personaID: $0.personaID, replyTo: $0.replyTo, replyToMe: $0.replyToMe,
                                         text: $0.text, createdAt: $0.createdAt)
                          })
            },
            album: album.map { AlbumDTO(id: $0.id, personaID: $0.personaID, data: $0.data, caption: $0.caption, createdAt: $0.createdAt) },
            prefs: prefs,
            myAvatar: MyAvatarStore.fileData,
            files: Dictionary(uniqueKeysWithValues: localFiles.compactMap { name in
                (try? Data(contentsOf: supportDir.appendingPathComponent(name))).map { (name, $0) }
            }),
            touches: try? PropertyListSerialization.data(
                fromPropertyList: defaults.dictionaryRepresentation().filter { key, _ in touchPrefixes.contains { key.hasPrefix($0) } },
                format: .binary, options: 0))
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

    static func restore(_ data: Data, context: ModelContext) async throws {
        // 拆包在后台做；往数据库里写回到主线程
        let archive = try await Task.detached(priority: .userInitiated) { try Backup.decode(data) }.value
        // 先删光再一条条写回：中途出错就整个撤销，现在的内容原样留着（不会被自动保存成「只删了一半」）
        do {
            try replaceAll(with: archive, context: context)
        } catch {
            context.rollback()
            throw error
        }

        let defaults = UserDefaults.standard
        for (key, value) in archive.prefs {
            if let n = Int(value) { defaults.set(n, forKey: key) }
            else if value == "1" || value == "0" { defaults.set(value == "1", forKey: key) }
            else { defaults.set(value, forKey: key) }
        }
        if let avatar = archive.myAvatar { MyAvatarStore.save(avatar) }
        // 旧备份里没有这些：原来的留着不动
        if let files = archive.files {
            for name in localFiles {
                let url = supportDir.appendingPathComponent(name)
                if let data = files[name] { try? data.write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) }
            }
            World.reload()
            Thoughts.shared.reload()
            VideoCards.shared.reload()
            CallLogs.shared.reload()
            ListenTogether.shared.reloadHistory()
        }
        if let touches = archive.touches,
           let saved = try? PropertyListSerialization.propertyList(from: touches, format: nil) as? [String: Any] {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("human.") { defaults.removeObject(forKey: key) }
            for (key, value) in saved { defaults.set(value, forKey: key) }
        }
        let todos = (try? context.fetch(FetchDescriptor<TodoItem>())) ?? []
        todos.forEach(Reminders.sync)
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

        for d in archive.personas {
            let p = Persona(name: d.name, tint: d.tint, bio: d.bio, systemPrompt: d.systemPrompt)
            p.id = d.id; p.avatarData = d.avatarData; p.engineRaw = d.engineRaw; p.model = d.model; p.effort = d.effort
            p.canWork = d.canWork; p.proactive = d.proactive; p.proactiveFreq = d.proactiveFreq; p.sortIndex = d.sortIndex
            p.createdAt = d.createdAt
            p.followUp = d.followUp ?? 1
            p.voiceID = d.voiceID ?? ""; p.voiceName = d.voiceName ?? ""; p.voiceFreq = d.voiceFreq ?? 0; p.language = d.language ?? "zh"; p.autoTranslate = d.autoTranslate ?? false
            p.voiceProvider = d.voiceProvider ?? "elevenlabs"; p.voiceModel = d.voiceModel ?? ""
            p.voiceSpeed = d.voiceSpeed ?? 1; p.voiceVolume = d.voiceVolume ?? 1
            p.voicePitch = d.voicePitch ?? 0; p.voiceEmotion = d.voiceEmotion ?? ""; p.voiceStyle = d.voiceStyle ?? ""
            p.momentsFreq = d.momentsFreq ?? 1; p.momentsMutual = d.momentsMutual ?? true
            context.insert(p)
        }
        for d in archive.conversations {
            let c = Conversation(title: d.title, isGroup: d.isGroup, memberIDs: d.memberIDs)
            c.id = d.id; c.pinned = d.pinned; c.draft = d.draft; c.createdAt = d.createdAt; c.updatedAt = d.updatedAt
            c.lastReadAt = d.lastReadAt; c.memory = d.memory; c.memoryUntil = d.memoryUntil; c.discussRounds = d.discussRounds
            context.insert(c)
            for md in d.messages {
                let m = Message(role: MessageRole(rawValue: md.roleRaw) ?? .user, kind: MessageKind(rawValue: md.kindRaw) ?? .text,
                                content: md.content, personaID: md.personaID)
                m.id = md.id; m.reasoning = md.reasoning; m.statusRaw = md.statusRaw; m.errorText = md.errorText
                m.modelLabel = md.modelLabel; m.steps = md.steps; m.quote = md.quote; m.isProactive = md.isProactive
                m.readAt = md.readAt; m.recalled = md.recalled; m.createdAt = md.createdAt; m.quoteID = md.quoteID
                m.translation = md.translation ?? ""
                m.momentID = md.momentID
                m.conversation = c
                context.insert(m)
                for ad in md.attachments {
                    let a = Attachment(kind: ad.kindRaw, fileName: ad.fileName, data: ad.data, order: ad.order)
                    a.message = m
                    context.insert(a)
                }
            }
        }
        for d in archive.todos {
            let t = TodoItem(title: d.title, notes: d.notes, dueDate: d.dueDate)
            t.id = d.id; t.isDone = d.isDone; t.hasTime = d.hasTime; t.remind = d.remind; t.remindLead = d.remindLead
            t.createdAt = d.createdAt; t.completedAt = d.completedAt
            context.insert(t)
        }
        for d in archive.diaries {
            let e = DiaryEntry(day: d.day, author: DiaryAuthor(rawValue: d.authorRaw) ?? .ai, text: d.text, mood: d.mood)
            e.id = d.id; e.personaID = d.personaID; e.createdAt = d.createdAt; e.reply = d.reply
            e.replyPersonaID = d.replyPersonaID; e.repliedText = d.repliedText
            context.insert(e)
        }
        for d in archive.stickers {
            let s = Sticker(pack: d.pack, data: d.data)
            s.id = d.id; s.createdAt = d.createdAt; s.lastUsedAt = d.lastUsedAt
            context.insert(s)
        }
        for d in archive.album ?? [] {
            let p = AlbumPhoto(personaID: d.personaID, data: d.data)
            p.id = d.id; p.caption = d.caption; p.createdAt = d.createdAt
            context.insert(p)
        }
        for d in archive.moments ?? [] {
            let m = Moment(personaID: d.personaID, text: d.text, mood: d.mood, createdAt: d.createdAt)
            m.id = d.id; m.photoIDs = d.photoIDs; m.voice = d.voice; m.likedBy = d.likedBy; m.likedByMe = d.likedByMe; m.reacted = d.reacted
            context.insert(m)
            for cd in d.comments {
                let c = MomentComment(personaID: cd.personaID, text: cd.text, replyTo: cd.replyTo, replyToMe: cd.replyToMe, createdAt: cd.createdAt)
                c.id = cd.id
                m.add(c, context: context)
            }
        }
        try context.save()
    }

    // MARK: 自动备份到电脑（每天一次）

    static func autoBackupIfNeeded(context: ModelContext, relay: RelayClient) async {
        let defaults = UserDefaults.standard
        guard !DemoMode.isOn, defaults.object(forKey: autoKey) as? Bool ?? true, relay.isConnected else { return }
        let now = Date.now.timeIntervalSince1970
        guard now - defaults.double(forKey: lastBackupKey) > 20 * 3600 else { return }
        // 刚失败过：隔两个小时再试，不要每次回到 App 都把几十 MB 重新打包、重新传一遍
        guard now - defaults.double(forKey: Prefs.backupFailedAt) > 2 * 3600 else { return }
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
