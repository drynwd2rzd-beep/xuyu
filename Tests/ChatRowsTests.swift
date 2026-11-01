import XCTest
import SwiftData
@testable import Xuyu

/// 聊天页排哪些行（ChatRows）：同一个人接着说合成一组、隔久了插时间、「已读」只挂在你最后一条下面、
/// 「正在输入」的小点在最底下、没到点的计划消息不出现、只排最近一段
@MainActor
final class ChatRowsTests: XCTestCase {
    private var savedRoot: URL!
    private var tempRoot: URL!
    /// 固定的起点：消息的时间都从这里往后数秒
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private var now: Date { base.addingTimeInterval(3600) }

    override func setUp() async throws {
        savedRoot = Storage.root
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("chat-rows-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        Storage.root = tempRoot
    }

    override func tearDown() async throws {
        Storage.root = savedRoot
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(Schema1.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    /// 在 base 之后 seconds 秒说一句；persona 为 nil 是你说的
    @discardableResult
    private func say(_ text: String, by persona: Persona?, at seconds: TimeInterval, in convo: Conversation, context: ModelContext) -> Message {
        let m = Message(role: persona == nil ? .user : .assistant, content: text, personaID: persona?.id)
        m.createdAt = base.addingTimeInterval(seconds)
        convo.add(m, context: context)
        return m
    }

    /// 把行写成一串好比对的字：时间行写「时间」，一组的第一条在正文后面加 *
    private func shape(_ rows: [ChatRow]) -> [String] {
        rows.map { row in
            switch row.kind {
            case .stamp: return "时间"
            case .message(let m, let first): return first ? "\(m.content)*" : m.content
            }
        }
    }

    private func single(_ context: ModelContext) -> (Persona, Conversation) {
        let persona = Persona(name: "TA")
        context.insert(persona)
        let convo = Conversation(isGroup: false, memberIDs: [persona.id])
        context.insert(convo)
        return (persona, convo)
    }

    func testRunOfYourMessagesGroupsAndReceiptOnLast() throws {
        let context = try makeContext()
        let (_, convo) = single(context)
        let messages = [say("a", by: nil, at: 0, in: convo, context: context),
                        say("b", by: nil, at: 30, in: convo, context: context),
                        say("c", by: nil, at: 60, in: convo, context: context)]
        messages.forEach { $0.readAt = base.addingTimeInterval(90) }

        let layout = ChatRows.make(convo, limit: 120, buffers: [:], now: now)

        XCTAssertEqual(shape(layout.rows), ["时间", "a*", "b", "c"], "隔不到 3 分钟算接着说，只有第一条带名字和头像")
        XCTAssertEqual(layout.receipt, messages[2].id, "「已读」只挂在最后一条下面")
        XCTAssertFalse(layout.hasEarlier)
        XCTAssertNil(layout.typing)
        XCTAssertEqual(layout.last?.id, messages[2].id)
    }

    func testAlternatingSpeakersAndReplyHidesReceipt() throws {
        let context = try makeContext()
        let (persona, convo) = single(context)
        say("在吗", by: nil, at: 0, in: convo, context: context)
        say("在", by: persona, at: 20, in: convo, context: context)
        let mine = say("吃了吗", by: nil, at: 40, in: convo, context: context)
        mine.readAt = base.addingTimeInterval(50)

        let before = ChatRows.make(convo, limit: 120, buffers: [:], now: now)
        XCTAssertEqual(shape(before.rows), ["时间", "在吗*", "在*", "吃了吗*"], "换了人就是新的一组")
        XCTAssertEqual(before.receipt, mine.id)

        say("吃了", by: persona, at: 60, in: convo, context: context)
        let after = ChatRows.make(convo, limit: 120, buffers: [:], now: now)
        XCTAssertNil(after.receipt, "TA 回了以后「已读」就不挂了")
        XCTAssertNotEqual(before.tail, after.tail, "多了一行，最下面一截算变了")
    }

    func testReceiptWaitsUntilTAHasRead() throws {
        let context = try makeContext()
        let (_, convo) = single(context)
        let mine = say("睡了吗", by: nil, at: 0, in: convo, context: context)

        XCTAssertNil(ChatRows.make(convo, limit: 120, buffers: [:], now: now).receipt, "TA 还没看")
        mine.readAt = now.addingTimeInterval(600)
        XCTAssertNil(ChatRows.make(convo, limit: 120, buffers: [:], now: now).receipt, "TA 在忙，已读排在以后")
        XCTAssertEqual(ChatRows.make(convo, limit: 120, buffers: [:], now: now.addingTimeInterval(601)).receipt, mine.id)
    }

    func testGroupSpeakersAndTimeStamps() throws {
        let context = try makeContext()
        let a = Persona(name: "甲")
        let b = Persona(name: "乙")
        context.insert(a)
        context.insert(b)
        let convo = Conversation(title: "群", isGroup: true, memberIDs: [a.id, b.id])
        context.insert(convo)
        say("1", by: a, at: 0, in: convo, context: context)
        say("2", by: a, at: 60, in: convo, context: context)
        say("3", by: b, at: 90, in: convo, context: context)
        // 同一个人隔了 3 分钟以上：新的一组，但不到 10 分钟不插时间
        say("4", by: b, at: 290, in: convo, context: context)
        // 隔了 10 分钟以上：插一行时间
        say("5", by: a, at: 990, in: convo, context: context)

        let layout = ChatRows.make(convo, limit: 120, buffers: [:], now: now)

        XCTAssertEqual(shape(layout.rows), ["时间", "1*", "2", "3*", "4*", "时间", "5*"])
        XCTAssertNil(layout.receipt, "你没说话，没有「已读」")
    }

    func testPlannedMessageAppearsOnlyWhenDue() throws {
        let context = try makeContext()
        let (persona, convo) = single(context)
        say("早", by: persona, at: 0, in: convo, context: context)
        let planned = say("在干嘛", by: persona, at: 7200, in: convo, context: context)
        planned.isProactive = true

        XCTAssertEqual(shape(ChatRows.make(convo, limit: 120, buffers: [:], now: now).rows), ["时间", "早*"], "还没到点的不出现")
        let due = base.addingTimeInterval(7200)
        XCTAssertEqual(shape(ChatRows.make(convo, limit: 120, buffers: [:], now: due).rows), ["时间", "早*", "时间", "在干嘛*"])
    }

    func testOnlyLatestWindowIsLaidOut() throws {
        let context = try makeContext()
        let (_, convo) = single(context)
        for i in 0..<130 { say("\(i)", by: nil, at: TimeInterval(i * 10), in: convo, context: context) }

        let layout = ChatRows.make(convo, limit: 120, buffers: [:], now: now)
        XCTAssertTrue(layout.hasEarlier, "更早的没排进来，顶上要有「查看更早的消息」")
        XCTAssertEqual(layout.rows.count, 121, "一行时间加最近 120 条")
        XCTAssertEqual(shape(layout.rows).prefix(3), ["时间", "10*", "11"])
        XCTAssertEqual(layout.last?.content, "129")

        let more = ChatRows.make(convo, limit: 240, buffers: [:], now: now)
        XCTAssertFalse(more.hasEarlier)
        XCTAssertEqual(more.rows.count, 131)
    }

    func testTypingDotsKeepReceiptUntilFirstWords() throws {
        let context = try makeContext()
        let (persona, convo) = single(context)
        let mine = say("你好", by: nil, at: 0, in: convo, context: context)
        mine.readAt = base.addingTimeInterval(5)
        let reply = say("打字中", by: persona, at: 10, in: convo, context: context)
        reply.status = .streaming
        let buffer = StreamBuffer()
        buffer.hold = true
        let buffers = [reply.id: buffer]

        let typing = ChatRows.make(convo, limit: 120, buffers: buffers, now: now)
        XCTAssertEqual(shape(typing.rows), ["时间", "你好*", "打字中*"], "小点接在最后")
        XCTAssertEqual(typing.typing?.id, reply.id)
        XCTAssertEqual(typing.last?.id, mine.id, "小点不算最后一条")
        XCTAssertEqual(typing.receipt, mine.id, "TA 只在打字时「已读」还留着")
        XCTAssertTrue(typing.live === buffer)

        // 你在小点出现后又说了一句：插在小点上面
        let more = say("在吗", by: nil, at: 20, in: convo, context: context)
        let inserted = ChatRows.make(convo, limit: 120, buffers: buffers, now: now)
        XCTAssertEqual(shape(inserted.rows), ["时间", "你好*", "在吗", "打字中*"])
        XCTAssertEqual(inserted.last?.id, more.id)

        // 第一句话冒出来：不再是小点，「已读」淡出
        buffer.hold = false
        let spoken = ChatRows.make(convo, limit: 120, buffers: buffers, now: now)
        XCTAssertNil(spoken.typing)
        XCTAssertEqual(shape(spoken.rows), ["时间", "你好*", "打字中*", "在吗*"], "按时间排回原位")
        XCTAssertNotEqual(inserted.tail, spoken.tail)
    }
}
