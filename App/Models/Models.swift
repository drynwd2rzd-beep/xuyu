import Foundation
import SwiftData

enum Engine: String, Codable, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var label: String { self == .claude ? "Claude" : "Codex" }
}

@Model
final class Persona {
    var id: UUID = UUID()
    var name: String = ""
    var bio: String = ""
    var systemPrompt: String = ""
    var tint: Int = 0x1E1E1F
    @Attribute(.externalStorage) var avatarData: Data?
    var engineRaw: String = Engine.claude.rawValue
    /// 空字符串表示使用设置里的默认模型
    var model: String = ""
    var proactive: Bool = false
    /// 0 偶尔 · 1 每天 · 2 常常
    var proactiveFreq: Int = 1
    var sortIndex: Int = 0
    var createdAt: Date = Date()

    init(name: String, engine: Engine = .claude, tint: Int = 0x1E1E1F, bio: String = "", systemPrompt: String = "") {
        self.name = name
        self.engineRaw = engine.rawValue
        self.tint = tint
        self.bio = bio
        self.systemPrompt = systemPrompt
    }

    var engine: Engine {
        get { Engine(rawValue: engineRaw) ?? .claude }
        set { engineRaw = newValue.rawValue }
    }

    /// 头像上显示的字：名字的第一个字符
    var initial: String { name.trimmed.first.map(String.init) ?? "?" }
}

@Model
final class Conversation {
    var id: UUID = UUID()
    var title: String = ""
    var isGroup: Bool = false
    var memberIDs: [UUID] = []
    var pinned: Bool = false
    var draft: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastReadAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation) var messages: [Message]? = []

    init(title: String = "", isGroup: Bool, memberIDs: [UUID]) {
        self.title = title
        self.isGroup = isGroup
        self.memberIDs = memberIDs
    }

    /// 已经「到达」的消息（主动消息会提前生成，到点才出现）
    func visibleMessages(at now: Date = .now) -> [Message] {
        (messages ?? []).filter { $0.createdAt <= now }.sorted { $0.createdAt < $1.createdAt }
    }

    func lastVisible(at now: Date = .now) -> Message? {
        (messages ?? []).filter { $0.createdAt <= now }.max { $0.createdAt < $1.createdAt }
    }

    func hasUnread(at now: Date = .now) -> Bool {
        guard let last = lastVisible(at: now) else { return false }
        return last.role == .assistant && last.createdAt > lastReadAt
    }

    func displayTitle(_ members: [Persona]) -> String {
        if !title.trimmed.isEmpty { return title }
        if isGroup { return members.isEmpty ? "群聊" : members.map(\.name).joined(separator: "、") }
        return members.first?.name ?? "已删除的角色"
    }
}

enum MessageRole: String { case user, assistant }
enum MessageKind: String { case text, images, file, note, sticker }
enum MessageStatus: String { case done, streaming, error }

@Model
final class Message {
    var id: UUID = UUID()
    var roleRaw: String = MessageRole.user.rawValue
    var kindRaw: String = MessageKind.text.rawValue
    var content: String = ""
    var reasoning: String = ""
    var personaID: UUID?
    var statusRaw: String = MessageStatus.done.rawValue
    var errorText: String?
    var modelLabel: String = ""
    /// 主动消息：提前生成，createdAt 是送达时间
    var isProactive: Bool = false
    var createdAt: Date = Date()
    var conversation: Conversation?
    @Relationship(deleteRule: .cascade, inverse: \Attachment.message) var attachments: [Attachment]? = []

    init(role: MessageRole, kind: MessageKind = .text, content: String, personaID: UUID? = nil) {
        self.roleRaw = role.rawValue
        self.kindRaw = kind.rawValue
        self.content = content
        self.personaID = personaID
    }

    var role: MessageRole { MessageRole(rawValue: roleRaw) ?? .user }
    var kind: MessageKind { MessageKind(rawValue: kindRaw) ?? .text }

    var status: MessageStatus {
        get { MessageStatus(rawValue: statusRaw) ?? .done }
        set { statusRaw = newValue.rawValue }
    }

    var sortedAttachments: [Attachment] {
        (attachments ?? []).sorted { $0.order < $1.order }
    }
}

@Model
final class Attachment {
    var id: UUID = UUID()
    /// image · file
    var kindRaw: String = "image"
    var fileName: String = ""
    var order: Int = 0
    @Attribute(.externalStorage) var data: Data = Data()
    var message: Message?

    init(kind: String, fileName: String, data: Data, order: Int) {
        self.kindRaw = kind
        self.fileName = fileName
        self.data = data
        self.order = order
    }

    var isImage: Bool { kindRaw == "image" }
}

@Model
final class TodoItem {
    var id: UUID = UUID()
    var title: String = ""
    var notes: String = ""
    var isDone: Bool = false
    /// 没有具体时间时是当天 0 点；nil 表示「随时」
    var dueDate: Date?
    var hasTime: Bool = false
    var remind: Bool = false
    var remindLead: Int = 0
    var createdAt: Date = Date()
    var completedAt: Date?

    init(title: String, notes: String = "", dueDate: Date? = nil) {
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
    }

    static func order(_ a: TodoItem, _ b: TodoItem) -> Bool {
        if a.isDone != b.isDone { return !a.isDone }
        switch (a.hasTime ? a.dueDate : nil, b.hasTime ? b.dueDate : nil) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.createdAt < b.createdAt
        }
    }
}

enum DiaryAuthor: String { case ai, me }

@Model
final class DiaryEntry {
    var id: UUID = UUID()
    var day: Date = Date()
    var authorRaw: String = DiaryAuthor.ai.rawValue
    var text: String = ""
    var mood: String = ""
    var personaID: UUID?
    var createdAt: Date = Date()

    init(day: Date, author: DiaryAuthor, text: String, mood: String = "") {
        self.day = day.startOfDay
        self.authorRaw = author.rawValue
        self.text = text
        self.mood = mood
    }

    var author: DiaryAuthor { DiaryAuthor(rawValue: authorRaw) ?? .ai }
}

@Model
final class Sticker {
    var id: UUID = UUID()
    var pack: String = "我的"
    @Attribute(.externalStorage) var data: Data = Data()
    var createdAt: Date = Date()
    var lastUsedAt: Date?

    init(pack: String, data: Data) {
        self.pack = pack
        self.data = data
    }
}

extension ModelContext {
    func conversation(_ id: UUID) -> Conversation? {
        try? fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first
    }

    func persona(_ id: UUID) -> Persona? {
        try? fetch(FetchDescriptor<Persona>(predicate: #Predicate { $0.id == id })).first
    }

    func allPersonas() -> [Persona] {
        (try? fetch(FetchDescriptor<Persona>(sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.createdAt)]))) ?? []
    }

    /// 角色对应的单聊（每个角色一段）
    func chat(for persona: Persona) -> Conversation {
        let pid = persona.id
        let all = (try? fetch(FetchDescriptor<Conversation>(predicate: #Predicate { !$0.isGroup }))) ?? []
        if let found = all.first(where: { $0.memberIDs == [pid] }) { return found }
        let convo = Conversation(isGroup: false, memberIDs: [pid])
        insert(convo)
        return convo
    }
}

enum Schema1 {
    static let models: [any PersistentModel.Type] = [Persona.self, Conversation.self, Message.self, Attachment.self,
                                                       TodoItem.self, DiaryEntry.self, Sticker.self]
}
