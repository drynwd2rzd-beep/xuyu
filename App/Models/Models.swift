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
    /// 推理强度，空字符串表示使用默认
    var effort: String = ""
    /// 工作模式：允许在电脑的工作文件夹里读写文件、运行命令
    var canWork: Bool = false
    var proactive: Bool = false
    /// 0 偶尔 · 1 每天 · 2 常常
    var proactiveFreq: Int = 1
    /// 你没回 TA 的消息时，TA 多久后来追问：0 不追问 · 1 20 分钟～1 小时 · 2 1～3 小时 · 3 3～6 小时
    var followUp: Int = 1
    /// 发语音用哪家：elevenlabs · minimax
    var voiceProvider: String = "elevenlabs"
    /// 这个角色用的语音模型（空 = 这家的默认模型）
    var voiceModel: String = ""
    /// 发语音用的声音（空 = 不发语音）
    var voiceID: String = ""
    var voiceName: String = ""
    /// 多常发语音：0 不发 · 1 偶尔 · 2 常常
    var voiceFreq: Int = 0
    /// TA 用哪种语言和你聊天、发语音：zh 中文 · ko 韩语
    var language: String = "zh"
    /// TA 发语音后自动在下面显示翻译
    var autoTranslate: Bool = false
    /// 声音调节：语速（1 = 正常）、音量（1 = 正常）、音调（0 = 正常，-12～12）、情绪（空 = 自动）
    var voiceSpeed: Double = 1
    var voiceVolume: Double = 1
    var voicePitch: Int = 0
    var voiceEmotion: String = ""
    /// 其余的声音设置（音色微调、音效、混合声音、读音纠正、ElevenLabs 的稳定性等），存成一段 JSON，见 VoiceStyle
    var voiceStyle: String = ""
    /// 多常发动态：0 不发 · 1 偶尔 · 2 常常
    var momentsFreq: Int = 1
    /// 会去看别的角色的动态，点赞、评论
    var momentsMutual: Bool = true
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
    /// 长期记忆：更早的聊天总结成的要点，每次聊天都会带上
    var memory: String = ""
    /// 这个时间（含）之前的消息已经总结进记忆，不再逐条发送
    var memoryUntil: Date = Date.distantPast
    /// 群聊自动讨论的轮数：1 = 每人回一次；更多轮时大家会接着彼此的话说
    var discussRounds: Int = 1
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation) var messages: [Message]? = []

    init(title: String = "", isGroup: Bool, memberIDs: [UUID]) {
        self.title = title
        self.isGroup = isGroup
        self.memberIDs = memberIDs
    }

    /// 已经「到达」的消息（主动消息会提前生成，到点才出现）
    /// 加一条消息。从对话这一边加，聊天页马上就能看到（在调用处的动画里一起出现）；
    /// 只设消息那一边的话，对话的消息列表要等保存以后才刷新，新气泡会在保存那一刻突然冒出来
    func add(_ message: Message, context: ModelContext) {
        context.insert(message)
        if messages == nil { messages = [message] } else { messages?.append(message) }
    }

    func visibleMessages(at now: Date = .now) -> [Message] {
        (messages ?? []).filter { $0.createdAt <= now }.sorted { $0.createdAt < $1.createdAt }
    }

    /// 提前生成好、还没到点的主动消息和追问
    func plannedMessages(after now: Date = .now) -> [Message] {
        (messages ?? []).filter { $0.isProactive && $0.createdAt > now }
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
enum MessageKind: String { case text, images, file, note, sticker, voice }
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
    /// 这条回复在电脑中继上的编号：App 被关掉后再打开，凭它取回没收完的回复
    var relayID: String = ""
    /// 工作模式里做过的步骤，一行一步；名字旁的小箭头可以展开看
    var steps: String = ""
    /// 长按「引用」时带上的那句话，例如「Claude：周六去植物园吧」
    var quote: String = ""
    /// 引用的原消息：点一下引用可以跳到原文
    var quoteID: UUID?
    /// 主动消息：提前生成，createdAt 是送达时间
    var isProactive: Bool = false
    /// 你发的消息被 TA「看到」的时间（显示已读双勾）
    var readAt: Date?
    /// 你撤回了这条消息
    var recalled: Bool = false
    /// 翻译（长按「翻译」或自动翻译语音时生成；空 = 没翻译或收起了）
    var translation: String = ""
    /// TA 在聊天里提起的那条动态（消息上面附一张小卡片）
    var momentID: UUID?
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
    /// 你写的日记：写日记的角色给你的回信
    var reply: String = ""
    var replyPersonaID: UUID?
    /// 回信时对应的那版日记内容（你改了日记，TA 会重新回）
    var repliedText: String = ""

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
                                                       TodoItem.self, DiaryEntry.self, Sticker.self,
                                                       Moment.self, MomentComment.self, AlbumPhoto.self]
}
