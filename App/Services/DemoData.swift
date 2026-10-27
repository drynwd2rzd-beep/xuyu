import Foundation
import SwiftData
import UIKit

/// 只用于 CI 截图的示例数据（内存数据库，不会写进真实数据）
enum DemoData {
    @MainActor
    static func populate(_ context: ModelContext) {
        let now = Date()
        let cal = Calendar.current
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        let defaults = UserDefaults.standard
        defaults.set("敏敏", forKey: Prefs.nickname)
        defaults.set("慢一点也没关系，秋天会等你走完这一程。", forKey: Prefs.whisperText)
        defaults.set("Claude", forKey: Prefs.whisperAuthor)
        defaults.set(Companion.dayKey, forKey: Prefs.whisperDay)

        let claude = Persona(name: "Claude", engine: .claude, tint: 0x1E1E1F, bio: "温柔聪明的伙伴")
        claude.createdAt = now.adding(days: -126)
        claude.proactive = true
        let codex = Persona(name: "Codex", engine: .codex, tint: 0xE7E3DA, bio: "擅长代码和动手")
        codex.sortIndex = 1
        let lin = Persona(name: "林间", engine: .claude, tint: 0xB7C3B1, bio: "安静的写作伙伴")
        lin.sortIndex = 2
        [claude, codex, lin].forEach { context.insert($0) }

        let chat = Conversation(isGroup: false, memberIDs: [claude.id])
        chat.updatedAt = ago(1)
        context.insert(chat)
        add(context, chat, .user, "帮我规划一下这周末，想放松一点，但也想把读书笔记整理完。", at: ago(9))
        add(context, chat, .assistant, """
        ### 周六 · 慢下来
        上午睡到自然醒，下午**两小时**整理笔记，傍晚去植物园走走。

        > 留白不是浪费，是给下一周蓄力。
        """, reasoning: "想放松，又有一个明确的任务。把整理笔记放在精力好的下午，控制时长，其余留白。", persona: claude, at: ago(8))
        let photos = add(context, chat, .user, "", kind: .images, at: ago(3))
        for (i, hex) in [0xE8D7B0, 0xC9D6DE, 0xD3DCCB].enumerated() {
            let a = Attachment(kind: "image", fileName: "IMG_\(4120 + i).jpg", data: placeholder(hex: UInt32(hex), symbol: i), order: i)
            a.message = photos
            context.insert(a)
        }
        add(context, chat, .user, "周六拍的，帮我挑一张当壁纸", at: ago(3))
        add(context, chat, .assistant, "选第二张。", persona: claude, at: ago(1.2))
        add(context, chat, .assistant, "银杏的黄和天空的蓝很干净，上方留白正好放时间，主体不会被挡住。^^", persona: claude, at: ago(1.1))

        let codexChat = Conversation(isGroup: false, memberIDs: [codex.id])
        codexChat.updatedAt = ago(40)
        context.insert(codexChat)
        add(context, codexChat, .assistant, "脚本已经改好了，记得先备份一下 notes 文件夹。", persona: codex, at: ago(40))
        let linChat = Conversation(isGroup: false, memberIDs: [lin.id])
        linChat.updatedAt = ago(60 * 20)
        context.insert(linChat)
        add(context, linChat, .assistant, "带本薄薄的诗集，风会替你翻书。", persona: lin, at: ago(60 * 20))

        let group = Conversation(title: "周末去哪儿", isGroup: true, memberIDs: [claude.id, lin.id, codex.id])
        group.pinned = true
        group.updatedAt = ago(12)
        context.insert(group)
        add(context, group, .user, "周末想出去走走", at: ago(24))
        add(context, group, .user, "大家有什么推荐？", at: ago(23.9))
        add(context, group, .assistant, "想安静一点的话，城郊植物园的银杏正好。", persona: claude, at: ago(23))
        add(context, group, .assistant, "我投植物园一票。", persona: lin, at: ago(22))
        add(context, group, .assistant, "带本薄薄的诗集，风会替你翻书。", persona: lin, at: ago(21.9))
        add(context, group, .user, "@Codex 那下午呢？", at: ago(13))
        add(context, group, .assistant, "旁边有旧书市集。", persona: codex, at: ago(12.1))
        add(context, group, .assistant, "四点前结束，正好避开晚高峰。", persona: codex, at: ago(12))
        [chat, codexChat, linChat, group].forEach { $0.lastReadAt = ago(2) }

        let today = now.startOfDay
        let items: [(String, Date?, Bool, Bool)] = [
            ("给妈妈打电话", cal.date(bySettingHour: 20, minute: 30, second: 0, of: now), false, true),
            ("预约植物园门票", today, false, false),
            ("整理读书笔记", nil, false, false),
            ("买咖啡豆", nil, true, false),
            ("周报", today.adding(days: 2), false, false),
            ("看牙医", cal.date(bySettingHour: 10, minute: 0, second: 0, of: today.adding(days: 5)), false, true),
        ]
        for (title, due, done, timed) in items {
            let item = TodoItem(title: title, dueDate: due)
            item.createdAt = ago(300)
            item.isDone = done
            item.completedAt = done ? ago(40) : nil
            item.hasTime = timed
            item.remind = timed
            item.remindLead = timed ? 10 : 0
            context.insert(item)
        }

        let diary = DiaryEntry(day: today, author: .ai,
                               text: "今天敏敏想把周末过得松一点，又放不下那叠读书笔记。我们把整理笔记塞进了周六下午，剩下的全部留白。晚上她发来三张植物园的照片，我挑了第二张当壁纸——银杏的黄配上干净的蓝，像一个刚刚好的秋天。",
                               mood: "惬意")
        diary.personaID = claude.id
        context.insert(diary)
        for (i, mood) in ["开心", "平静", "累了", "惬意"].enumerated() {
            let past = DiaryEntry(day: today.adding(days: -(i + 1)), author: .ai, text: "……", mood: mood)
            context.insert(past)
        }
        try? context.save()
    }

    @MainActor
    @discardableResult
    private static func add(_ context: ModelContext, _ convo: Conversation, _ role: MessageRole, _ text: String,
                            kind: MessageKind = .text, reasoning: String = "", persona: Persona? = nil, at date: Date) -> Message {
        let m = Message(role: role, kind: kind, content: text, personaID: persona?.id)
        m.reasoning = reasoning
        m.createdAt = date
        m.conversation = convo
        context.insert(m)
        return m
    }

    static func placeholder(hex: UInt32, symbol: Int) -> Data {
        let size = CGSize(width: 900, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(hex: hex).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let names = ["leaf", "cloud.sun", "tree"]
            let config = UIImage.SymbolConfiguration(pointSize: 260, weight: .ultraLight)
            if let symbol = UIImage(systemName: names[symbol % names.count], withConfiguration: config)?
                .withTintColor(UIColor.black.withAlphaComponent(0.35), renderingMode: .alwaysOriginal) {
                let s = symbol.size
                symbol.draw(in: CGRect(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2, width: s.width, height: s.height))
            }
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
}
