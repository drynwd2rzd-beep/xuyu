import Foundation
import SwiftData

// 备份里每种数据的样子，和它跟数据库模型之间的来回转换：一种数据只在这里写一遍（DATA-7）。
// 字段名就是备份文件里的键名，已经发出去的不能改名；新加的字段一律写成可选（?），旧备份里没有它也能恢复。
// 测试 testBackupCoversEveryField 会检查每个模型的每个字段都在这里有着落

extension Backup {
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

        init(_ p: Persona) {
            id = p.id; name = p.name; bio = p.bio; systemPrompt = p.systemPrompt; tint = p.tint; avatarData = p.avatarData
            engineRaw = p.engineRaw; model = p.model; effort = p.effort; canWork = p.canWork
            proactive = p.proactive; proactiveFreq = p.proactiveFreq; sortIndex = p.sortIndex; createdAt = p.createdAt
            followUp = p.followUp
            voiceID = p.voiceID; voiceName = p.voiceName; voiceFreq = p.voiceFreq; language = p.language; autoTranslate = p.autoTranslate
            voiceProvider = p.voiceProvider; voiceModel = p.voiceModel
            voiceSpeed = p.voiceSpeed; voiceVolume = p.voiceVolume; voicePitch = p.voicePitch; voiceEmotion = p.voiceEmotion
            voiceStyle = p.voiceStyle
            momentsFreq = p.momentsFreq; momentsMutual = p.momentsMutual
        }

        /// 旧备份里没有的项：用模型自己的默认值
        func make() -> Persona {
            let p = Persona(name: name, tint: tint, bio: bio, systemPrompt: systemPrompt)
            p.id = id; p.avatarData = avatarData; p.engineRaw = engineRaw; p.model = model; p.effort = effort
            p.canWork = canWork; p.proactive = proactive; p.proactiveFreq = proactiveFreq; p.sortIndex = sortIndex
            p.createdAt = createdAt
            p.followUp = followUp ?? p.followUp
            p.voiceID = voiceID ?? p.voiceID; p.voiceName = voiceName ?? p.voiceName; p.voiceFreq = voiceFreq ?? p.voiceFreq
            p.language = language ?? p.language; p.autoTranslate = autoTranslate ?? p.autoTranslate
            p.voiceProvider = voiceProvider ?? p.voiceProvider; p.voiceModel = voiceModel ?? p.voiceModel
            p.voiceSpeed = voiceSpeed ?? p.voiceSpeed; p.voiceVolume = voiceVolume ?? p.voiceVolume
            p.voicePitch = voicePitch ?? p.voicePitch; p.voiceEmotion = voiceEmotion ?? p.voiceEmotion; p.voiceStyle = voiceStyle ?? p.voiceStyle
            p.momentsFreq = momentsFreq ?? p.momentsFreq; p.momentsMutual = momentsMutual ?? p.momentsMutual
            return p
        }
    }

    struct ConversationDTO: Codable {
        var id: UUID, title: String, isGroup: Bool, memberIDs: [UUID], pinned: Bool, draft: String
        var createdAt: Date, updatedAt: Date, lastReadAt: Date, memory: String, memoryUntil: Date, discussRounds: Int
        var messages: [MessageDTO]

        /// 正在生成的半截回复不备份
        init(_ c: Conversation) {
            id = c.id; title = c.title; isGroup = c.isGroup; memberIDs = c.memberIDs; pinned = c.pinned; draft = c.draft
            createdAt = c.createdAt; updatedAt = c.updatedAt; lastReadAt = c.lastReadAt; memory = c.memory
            memoryUntil = c.memoryUntil; discussRounds = c.discussRounds
            messages = (c.messages ?? []).filter { $0.status != .streaming }.map { MessageDTO($0) }
        }

        /// 连同消息和附件一起放进数据库
        func insert(into context: ModelContext) {
            let c = Conversation(title: title, isGroup: isGroup, memberIDs: memberIDs)
            c.id = id; c.pinned = pinned; c.draft = draft; c.createdAt = createdAt; c.updatedAt = updatedAt
            c.lastReadAt = lastReadAt; c.memory = memory; c.memoryUntil = memoryUntil; c.discussRounds = discussRounds
            context.insert(c)
            for md in messages { md.insert(into: c, context: context) }
        }
    }

    struct MessageDTO: Codable {
        var id: UUID, roleRaw: String, kindRaw: String, content: String, reasoning: String, personaID: UUID?
        var statusRaw: String, errorText: String?, modelLabel: String, steps: String, quote: String
        var isProactive: Bool, readAt: Date?, recalled: Bool, createdAt: Date
        var quoteID: UUID?
        var translation: String?
        var momentID: UUID?
        var attachments: [AttachmentDTO]

        init(_ m: Message) {
            id = m.id; roleRaw = m.roleRaw; kindRaw = m.kindRaw; content = m.content; reasoning = m.reasoning; personaID = m.personaID
            statusRaw = m.statusRaw; errorText = m.errorText; modelLabel = m.modelLabel; steps = m.steps; quote = m.quote
            isProactive = m.isProactive; readAt = m.readAt; recalled = m.recalled; createdAt = m.createdAt
            quoteID = m.quoteID; translation = m.translation; momentID = m.momentID
            attachments = m.sortedAttachments.map { AttachmentDTO($0) }
        }

        func insert(into c: Conversation, context: ModelContext) {
            let m = Message(role: MessageRole(rawValue: roleRaw) ?? .user, kind: MessageKind(rawValue: kindRaw) ?? .text,
                            content: content, personaID: personaID)
            m.id = id; m.reasoning = reasoning; m.statusRaw = statusRaw; m.errorText = errorText
            m.modelLabel = modelLabel; m.steps = steps; m.quote = quote; m.isProactive = isProactive
            m.readAt = readAt; m.recalled = recalled; m.createdAt = createdAt; m.quoteID = quoteID
            m.translation = translation ?? m.translation
            m.momentID = momentID
            m.conversation = c
            context.insert(m)
            for ad in attachments { ad.insert(into: m, context: context) }
        }
    }

    struct AttachmentDTO: Codable {
        var kindRaw: String, fileName: String, order: Int, data: Data

        init(_ a: Attachment) {
            kindRaw = a.kindRaw; fileName = a.fileName; order = a.order; data = a.data
        }

        func insert(into m: Message, context: ModelContext) {
            let a = Attachment(kind: .file, fileName: fileName, data: data, order: order)
            // 种类原样还原（认不出的旧种类也不改写）
            a.kindRaw = kindRaw
            a.message = m
            context.insert(a)
        }
    }

    struct TodoDTO: Codable {
        var id: UUID, title: String, notes: String, isDone: Bool, dueDate: Date?, hasTime: Bool
        var remind: Bool, remindLead: Int, createdAt: Date, completedAt: Date?

        init(_ t: TodoItem) {
            id = t.id; title = t.title; notes = t.notes; isDone = t.isDone; dueDate = t.dueDate; hasTime = t.hasTime
            remind = t.remind; remindLead = t.remindLead; createdAt = t.createdAt; completedAt = t.completedAt
        }

        func make() -> TodoItem {
            let t = TodoItem(title: title, notes: notes, dueDate: dueDate)
            t.id = id; t.isDone = isDone; t.hasTime = hasTime; t.remind = remind; t.remindLead = remindLead
            t.createdAt = createdAt; t.completedAt = completedAt
            return t
        }
    }

    struct DiaryDTO: Codable {
        var id: UUID, day: Date, authorRaw: String, text: String, mood: String, personaID: UUID?, createdAt: Date
        var reply: String, replyPersonaID: UUID?, repliedText: String

        init(_ e: DiaryEntry) {
            id = e.id; day = e.day; authorRaw = e.authorRaw; text = e.text; mood = e.mood; personaID = e.personaID
            createdAt = e.createdAt; reply = e.reply; replyPersonaID = e.replyPersonaID; repliedText = e.repliedText
        }

        func make() -> DiaryEntry {
            let e = DiaryEntry(day: day, author: DiaryAuthor(rawValue: authorRaw) ?? .ai, text: text, mood: mood)
            e.id = id; e.personaID = personaID; e.createdAt = createdAt; e.reply = reply
            e.replyPersonaID = replyPersonaID; e.repliedText = repliedText
            return e
        }
    }

    struct MomentDTO: Codable {
        var id: UUID, personaID: UUID?, text: String, mood: String, photoIDs: [UUID], voice: Data?
        var likedBy: [UUID], likedByMe: Bool, reacted: Bool, createdAt: Date
        var comments: [CommentDTO]

        init(_ m: Moment) {
            id = m.id; personaID = m.personaID; text = m.text; mood = m.mood; photoIDs = m.photoIDs; voice = m.voice
            likedBy = m.likedBy; likedByMe = m.likedByMe; reacted = m.reacted; createdAt = m.createdAt
            comments = (m.comments ?? []).map { CommentDTO($0) }
        }

        func insert(into context: ModelContext) {
            let m = Moment(personaID: personaID, text: text, mood: mood, createdAt: createdAt)
            m.id = id; m.photoIDs = photoIDs; m.voice = voice; m.likedBy = likedBy; m.likedByMe = likedByMe; m.reacted = reacted
            context.insert(m)
            for cd in comments { m.add(cd.make(), context: context) }
        }
    }

    struct CommentDTO: Codable {
        var id: UUID, personaID: UUID?, replyTo: UUID?, replyToMe: Bool, text: String, createdAt: Date

        init(_ c: MomentComment) {
            id = c.id; personaID = c.personaID; replyTo = c.replyTo; replyToMe = c.replyToMe; text = c.text; createdAt = c.createdAt
        }

        func make() -> MomentComment {
            let c = MomentComment(personaID: personaID, text: text, replyTo: replyTo, replyToMe: replyToMe, createdAt: createdAt)
            c.id = id
            return c
        }
    }

    struct AlbumDTO: Codable {
        var id: UUID, personaID: UUID?, data: Data, caption: String, createdAt: Date

        init(_ p: AlbumPhoto) {
            id = p.id; personaID = p.personaID; data = p.data; caption = p.caption; createdAt = p.createdAt
        }

        func make() -> AlbumPhoto {
            let p = AlbumPhoto(personaID: personaID, data: data)
            p.id = id; p.caption = caption; p.createdAt = createdAt
            return p
        }
    }

    struct StickerDTO: Codable {
        var id: UUID, pack: String, data: Data, createdAt: Date, lastUsedAt: Date?

        init(_ s: Sticker) {
            id = s.id; pack = s.pack; data = s.data; createdAt = s.createdAt; lastUsedAt = s.lastUsedAt
        }

        func make() -> Sticker {
            let s = Sticker(pack: pack, data: data)
            s.id = id; s.createdAt = createdAt; s.lastUsedAt = lastUsedAt
            return s
        }
    }
}
