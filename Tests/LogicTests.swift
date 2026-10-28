import XCTest
import SwiftData
@testable import Xuyu

/// 核心逻辑的自动测试：每次推送都在云端跑一遍，改坏了会马上发现
@MainActor
final class LogicTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema(Schema1.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    private func message(_ role: MessageRole, _ text: String, at date: Date, persona: Persona? = nil,
                         in convo: Conversation, context: ModelContext) -> Message {
        let m = Message(role: role, content: text, personaID: persona?.id)
        m.createdAt = date
        m.conversation = convo
        context.insert(m)
        return m
    }

    // MARK: - 回复拆成几条

    func testParagraphsSplitOnBlankLines() {
        XCTAssertEqual(ReplyText.paragraphs("早呀\n\n今天想做什么？\n\n", whole: false), ["早呀", "今天想做什么？"])
    }

    func testFormattedReplyStaysWhole() {
        let text = "可以这样：\n- 先吃饭\n- 再散步\n\n就这样"
        XCTAssertEqual(ReplyText.paragraphs(text, whole: false).count, 1)
    }

    func testWorkReportStaysWhole() {
        XCTAssertEqual(ReplyText.paragraphs("做好了\n\n文件在桌面", whole: true), ["做好了\n\n文件在桌面"])
    }

    // MARK: - 表情和引用标记

    func testQuoteAndStickerMarkers() {
        let m = ReplyText.markers(in: "【引用:火锅】好呀好呀\n\n【表情:猫猫】")
        XCTAssertEqual(m.body, "好呀好呀")
        XCTAssertEqual(m.quoteKey, "火锅")
        XCTAssertEqual(m.stickerPacks, ["猫猫"])
    }

    func testEnglishBracketsAndSeveralStickers() {
        let m = ReplyText.markers(in: "[表情：狗狗]哈哈[表情:猫猫]")
        XCTAssertEqual(m.body, "哈哈")
        XCTAssertEqual(m.stickerPacks, ["狗狗", "猫猫"])
    }

    func testFakeStickerTextIsRemoved() {
        let m = ReplyText.markers(in: "笑死我了【捂脸表情】")
        XCTAssertEqual(m.body, "笑死我了")
        XCTAssertTrue(m.stickerPacks.isEmpty)
    }

    func testQuotedFindsLatestUnrecalledMessage() throws {
        let context = try makeContext()
        let convo = Conversation(isGroup: false, memberIDs: [])
        context.insert(convo)
        let now = Date.now
        let hotpot = message(.user, "今晚吃火锅吗", at: now.addingTimeInterval(-60), in: convo, context: context)
        let rain = message(.user, "明天好像下雨", at: now, in: convo, context: context)
        rain.recalled = true
        let all = convo.visibleMessages()
        XCTAssertEqual(ReplyText.quoted("火锅", in: all)?.id, hotpot.id)
        XCTAssertNil(ReplyText.quoted("下雨", in: all))
        XCTAssertEqual(ReplyText.quoteLine(for: hotpot), "你：今晚吃火锅吗")
    }

    func testQuoteSourceByIDThenByText() throws {
        let context = try makeContext()
        let convo = Conversation(isGroup: false, memberIDs: [])
        context.insert(convo)
        let now = Date.now
        let original = message(.assistant, "银杏的黄和天空的蓝很干净", at: now.addingTimeInterval(-30), in: convo, context: context)
        let all = convo.visibleMessages()
        XCTAssertEqual(ReplyText.source(ofQuote: "Claude：随便", id: original.id, in: all)?.id, original.id)
        // 没有编号（旧消息）：按文字找，名字前缀和省略号不影响
        XCTAssertEqual(ReplyText.source(ofQuote: "Claude：银杏的黄和天空…", id: nil, in: all)?.id, original.id)
        XCTAssertNil(ReplyText.source(ofQuote: "我：完全没说过的话", id: UUID(), in: all))
    }

    func testVoiceMarker() {
        let m = ReplyText.markers(in: "【语音】嗯…今天辛苦啦，早点睡哈")
        XCTAssertTrue(m.voice)
        XCTAssertEqual(m.body, "嗯…今天辛苦啦，早点睡哈")
        XCTAssertFalse(ReplyText.markers(in: "普通的一句话").voice)
        XCTAssertEqual(VoiceBubble.bars(for: 1), 7)
        XCTAssertEqual(VoiceBubble.bars(for: 60), 26)
        XCTAssertEqual(Waveform.heights(seed: "a", count: 9), Waveform.heights(seed: "a", count: 9))
    }

    func testKoreanPersonaSpeaksKorean() {
        let karina = Persona(name: "Karina")
        XCTAssertFalse(PromptBuilder.system(for: karina, convo: nil, members: [karina]).contains("说韩语"))
        karina.language = "ko"
        XCTAssertTrue(PromptBuilder.system(for: karina, convo: nil, members: [karina]).contains("说韩语"))
        XCTAssertTrue(Companion.endedNaturally(["오늘 고마웠어, 잘 자"]))
    }

    // MARK: - 约定

    func testPromiseMarkers() {
        let m = ReplyText.markers(in: "好呀，八点准时催你\n\n【约定:20:00|催睡觉】")
        XCTAssertEqual(m.body, "好呀，八点准时催你")
        XCTAssertEqual(m.promises, [ReplyText.Promise(time: "20:00", what: "催睡觉")])
        let c = ReplyText.markers(in: "好，那就不催啦【取消约定：催睡觉】")
        XCTAssertEqual(c.body, "好，那就不催啦")
        XCTAssertEqual(c.cancels, ["催睡觉"])
        XCTAssertTrue(c.promises.isEmpty)
    }

    func testAppointmentTimes() throws {
        let cal = Calendar.current
        let now = try XCTUnwrap(cal.date(bySettingHour: 19, minute: 0, second: 0, of: .now))
        let eight = try XCTUnwrap(Appointments.parseTime("20:00", now: now))
        XCTAssertEqual(eight.date, cal.date(bySettingHour: 20, minute: 0, second: 0, of: now))
        XCTAssertFalse(eight.daily)
        // 已经过了的钟点就是明天
        let morning = try XCTUnwrap(Appointments.parseTime("08:30", now: now))
        XCTAssertEqual(morning.date, cal.date(bySettingHour: 8, minute: 30, second: 0, of: now)?.adding(days: 1))
        XCTAssertEqual(Appointments.parseTime("+30分钟", now: now)?.date, now.addingTimeInterval(1800))
        XCTAssertEqual(Appointments.parseTime("+2小时", now: now)?.date, now.addingTimeInterval(7200))
        XCTAssertEqual(Appointments.parseTime("明天 7:00", now: now)?.date,
                       cal.date(bySettingHour: 7, minute: 0, second: 0, of: now)?.adding(days: 1))
        let daily = try XCTUnwrap(Appointments.parseTime("每天 22：30", now: now))
        XCTAssertTrue(daily.daily)
        XCTAssertEqual(cal.component(.hour, from: daily.date), 22)
        XCTAssertNil(Appointments.parseTime("晚上", now: now))
    }

    // MARK: - 谁来回复

    func testResponders() {
        let a = Persona(name: "小A"), b = Persona(name: "小B")
        let single = Conversation(isGroup: false, memberIDs: [a.id])
        let group = Conversation(isGroup: true, memberIDs: [a.id, b.id])
        XCTAssertEqual(ChatEngine.responders(for: "在吗", convo: single, members: [a]).map(\.name), ["小A"])
        XCTAssertEqual(ChatEngine.responders(for: "@小B 你好", convo: group, members: [a, b]).map(\.name), ["小B"])
        XCTAssertEqual(ChatEngine.responders(for: "@所有人 开会", convo: group, members: [a, b]).map(\.name), ["小A", "小B"])
        XCTAssertEqual(ChatEngine.responders(for: "大家好", convo: group, members: [a, b]).map(\.name), ["小A", "小B"])
        XCTAssertEqual(ChatEngine.merge([b], [a, b]).map(\.name), ["小B", "小A"])
    }

    // MARK: - 聊天间隔

    func testGapNote() throws {
        let context = try makeContext()
        let persona = Persona(name: "TA")
        context.insert(persona)
        let convo = Conversation(isGroup: false, memberIDs: [persona.id])
        context.insert(convo)
        let start = Date.now.addingTimeInterval(-10 * 86400)
        _ = message(.assistant, "晚安", at: start, persona: persona, in: convo, context: context)
        // 隔了 4 天，连发两条：从第一条算
        _ = message(.user, "在吗", at: start.addingTimeInterval(4 * 86400), in: convo, context: context)
        _ = message(.user, "好久不见", at: start.addingTimeInterval(4 * 86400 + 5), in: convo, context: context)
        XCTAssertTrue(PromptBuilder.gapNote(convo.visibleMessages()).contains("好久没聊"))
    }

    func testGapNoteHalfDayAndShort() throws {
        let context = try makeContext()
        let persona = Persona(name: "TA")
        context.insert(persona)
        let convo = Conversation(isGroup: false, memberIDs: [persona.id])
        context.insert(convo)
        let start = Date.now.addingTimeInterval(-86400)
        _ = message(.assistant, "去忙吧", at: start, persona: persona, in: convo, context: context)
        let reply = message(.user, "我回来啦", at: start.addingTimeInterval(13 * 3600), in: convo, context: context)
        XCTAssertTrue(PromptBuilder.gapNote(convo.visibleMessages()).contains("心里知道"))
        reply.createdAt = start.addingTimeInterval(600)
        XCTAssertEqual(PromptBuilder.gapNote(convo.visibleMessages()), "")
    }

    // MARK: - 记忆窗口

    func testRecentSkipsSummarizedAndCapsWindow() throws {
        let context = try makeContext()
        let convo = Conversation(isGroup: false, memberIDs: [])
        context.insert(convo)
        let start = Date.now.addingTimeInterval(-86400)
        for i in 0..<(Memory.maxWindow + 30) {
            _ = message(.user, "第\(i)条", at: start.addingTimeInterval(Double(i)), in: convo, context: context)
        }
        convo.memoryUntil = start.addingTimeInterval(9)
        let recent = PromptBuilder.recent(convo.visibleMessages(), convo: convo)
        XCTAssertEqual(recent.count, Memory.maxWindow)
        XCTAssertEqual(recent.last?.content, "第\(Memory.maxWindow + 29)条")
        XCTAssertTrue(recent.allSatisfy { $0.createdAt > convo.memoryUntil })
    }

    // MARK: - 群聊里每个人都能看到你的图

    func testEachPersonaSeesNewImages() throws {
        let context = try makeContext()
        let a = Persona(name: "小A"), b = Persona(name: "小B")
        context.insert(a); context.insert(b)
        let convo = Conversation(isGroup: true, memberIDs: [a.id, b.id])
        context.insert(convo)
        let now = Date.now
        let photo = message(.user, "看", at: now.addingTimeInterval(-10), in: convo, context: context)
        let image = Attachment(kind: "image", fileName: "a.jpg", data: Data([1, 2, 3]), order: 0)
        image.message = photo
        context.insert(image)
        _ = message(.assistant, "好看", at: now, persona: a, in: convo, context: context)
        try context.save()
        let history = convo.visibleMessages()
        XCTAssertTrue(PromptBuilder.newAttachments(for: a, in: history).isEmpty)
        XCTAssertEqual(PromptBuilder.newAttachments(for: b, in: history).count, 1)
    }

    // MARK: - 追问和免打扰

    func testFarewellEndsConversation() {
        XCTAssertTrue(Companion.endedNaturally(["我去洗澡啦", "好，晚安"]))
        XCTAssertTrue(Companion.endedNaturally(["先忙了，回头聊"]))
        XCTAssertTrue(Companion.endedNaturally(["OK Bye"]))
        XCTAssertFalse(Companion.endedNaturally(["今天吃了 188 块的火锅", "好吃吗？"]))
    }

    func testFollowUpRanges() {
        XCTAssertEqual(Companion.followUpRange(1), 1200...3600)
        XCTAssertEqual(Companion.followUpRange(2), 3600...10800)
        XCTAssertEqual(Companion.followUpRange(3), 10800...21600)
    }

    func testQuietHoursAcrossMidnight() {
        let d = UserDefaults.standard
        let saved = (d.object(forKey: Prefs.quietStart), d.object(forKey: Prefs.quietEnd))
        defer {
            d.set(saved.0, forKey: Prefs.quietStart)
            d.set(saved.1, forKey: Prefs.quietEnd)
        }
        d.set(23, forKey: Prefs.quietStart)
        d.set(8, forKey: Prefs.quietEnd)
        let day = Date.now.startOfDay
        XCTAssertTrue(Prefs.isQuiet(day.addingTimeInterval(2 * 3600)))
        XCTAssertTrue(Prefs.isQuiet(day.addingTimeInterval(23.5 * 3600)))
        XCTAssertFalse(Prefs.isQuiet(day.addingTimeInterval(12 * 3600)))
    }

    // MARK: - 备份再恢复，内容一样

    func testBackupRoundTrip() throws {
        let source = try makeContext()
        let persona = Persona(name: "TA", systemPrompt: "温柔")
        persona.followUp = 2
        source.insert(persona)
        let convo = Conversation(isGroup: false, memberIDs: [persona.id])
        convo.memory = "喜欢火锅"
        source.insert(convo)
        let now = Date.now
        let asked = message(.user, "吃火锅吗", at: now.addingTimeInterval(-5), in: convo, context: source)
        asked.readAt = now
        let answer = message(.assistant, "好呀", at: now, persona: persona, in: convo, context: source)
        answer.quote = "你：吃火锅吗"
        answer.quoteID = asked.id
        source.insert(TodoItem(title: "买菜"))
        source.insert(DiaryEntry(day: now.startOfDay, author: .me, text: "今天很开心", mood: "开心"))
        source.insert(Sticker(pack: "猫猫", data: Data([7])))
        try source.save()

        let data = try Backup.export(context: source)
        let target = try makeContext()
        try Backup.restore(data, context: target)

        let personas = try target.fetch(FetchDescriptor<Persona>())
        XCTAssertEqual(personas.map(\.name), ["TA"])
        XCTAssertEqual(personas.first?.followUp, 2)
        let convos = try target.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(convos.first?.memory, "喜欢火锅")
        let messages = convos.first?.visibleMessages() ?? []
        XCTAssertEqual(messages.map(\.content), ["吃火锅吗", "好呀"])
        XCTAssertNotNil(messages.first?.readAt)
        XCTAssertEqual(messages.last?.quoteID, asked.id)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<TodoItem>()), 1)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<DiaryEntry>()), 1)
        XCTAssertEqual(try target.fetch(FetchDescriptor<Sticker>()).first?.pack, "猫猫")
    }
}
