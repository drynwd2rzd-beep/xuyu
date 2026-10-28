import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 备份：把角色、聊天（含图片和文件）、待办、日记、表情、记忆和主要设置打包成一个文件；
/// 可以导出到「文件」、从文件恢复，也可以每天自动备份到电脑
@MainActor
enum Backup {
    static let version = 1
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
        var prefs: [String: String]
        var myAvatar: Data?
    }

    struct PersonaDTO: Codable {
        var id: UUID, name: String, bio: String, systemPrompt: String, tint: Int, avatarData: Data?
        var engineRaw: String, model: String, effort: String, canWork: Bool
        var proactive: Bool, proactiveFreq: Int, sortIndex: Int, createdAt: Date
        var followUp: Int?
        var voiceID: String?, voiceName: String?, voiceFreq: Int?, language: String?, autoTranslate: Bool?
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

    struct StickerDTO: Codable {
        var id: UUID, pack: String, data: Data, createdAt: Date, lastUsedAt: Date?
    }

    /// 一起备份的设置
    private static let prefKeys = [Prefs.nickname, Prefs.appearance, Prefs.wallpaper, Prefs.defaultClaudeModel, Prefs.defaultCodexModel,
                                   Prefs.defaultClaudeEffort, Prefs.defaultCodexEffort, Prefs.inAppBanner, Prefs.todoReminders,
                                   Prefs.diaryReminder, Prefs.quietStart, Prefs.quietEnd, Prefs.homeWidgets, Prefs.showEngineLogo,
                                   Prefs.diaryWriter, Prefs.showMyDiary, Prefs.stickerPackOrder, Prefs.appointments]

    // MARK: 导出

    static func export(context: ModelContext) throws -> Data {
        let personas = (try? context.fetch(FetchDescriptor<Persona>())) ?? []
        let convos = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        let todos = (try? context.fetch(FetchDescriptor<TodoItem>())) ?? []
        let diaries = (try? context.fetch(FetchDescriptor<DiaryEntry>())) ?? []
        let stickers = (try? context.fetch(FetchDescriptor<Sticker>())) ?? []
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
                           voiceID: $0.voiceID, voiceName: $0.voiceName, voiceFreq: $0.voiceFreq, language: $0.language, autoTranslate: $0.autoTranslate)
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
            prefs: prefs,
            myAvatar: MyAvatarStore.image?.jpegData(compressionQuality: 0.9))
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

    static func restore(_ data: Data, context: ModelContext) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let archive = try decoder.decode(Archive.self, from: data)

        try context.delete(model: Attachment.self)
        try context.delete(model: Message.self)
        try context.delete(model: Conversation.self)
        try context.delete(model: Persona.self)
        try context.delete(model: TodoItem.self)
        try context.delete(model: DiaryEntry.self)
        try context.delete(model: Sticker.self)

        for d in archive.personas {
            let p = Persona(name: d.name, tint: d.tint, bio: d.bio, systemPrompt: d.systemPrompt)
            p.id = d.id; p.avatarData = d.avatarData; p.engineRaw = d.engineRaw; p.model = d.model; p.effort = d.effort
            p.canWork = d.canWork; p.proactive = d.proactive; p.proactiveFreq = d.proactiveFreq; p.sortIndex = d.sortIndex
            p.createdAt = d.createdAt
            p.followUp = d.followUp ?? 1
            p.voiceID = d.voiceID ?? ""; p.voiceName = d.voiceName ?? ""; p.voiceFreq = d.voiceFreq ?? 0; p.language = d.language ?? "zh"; p.autoTranslate = d.autoTranslate ?? false
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
        try context.save()

        let defaults = UserDefaults.standard
        for (key, value) in archive.prefs {
            if let n = Int(value) { defaults.set(n, forKey: key) }
            else if value == "1" || value == "0" { defaults.set(value == "1", forKey: key) }
            else { defaults.set(value, forKey: key) }
        }
        if let avatar = archive.myAvatar { MyAvatarStore.save(avatar) }
        let todos = (try? context.fetch(FetchDescriptor<TodoItem>())) ?? []
        todos.forEach(Reminders.sync)
    }

    // MARK: 自动备份到电脑（每天一次）

    static func autoBackupIfNeeded(context: ModelContext, relay: RelayClient) async {
        let defaults = UserDefaults.standard
        guard !DemoMode.isOn, defaults.object(forKey: autoKey) as? Bool ?? true, relay.isConnected else { return }
        let last = defaults.double(forKey: lastBackupKey)
        guard Date.now.timeIntervalSince1970 - last > 20 * 3600 else { return }
        await backupToPC(context: context, relay: relay)
    }

    @discardableResult
    static func backupToPC(context: ModelContext, relay: RelayClient) async -> Bool {
        guard let data = try? export(context: context) else { return false }
        let ok = await relay.saveBackup(name: fileName, data: data)
        if ok { UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: lastBackupKey) }
        return ok
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
