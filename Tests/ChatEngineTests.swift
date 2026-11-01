import XCTest
import SwiftData
@testable import Xuyu

/// 发送的状态机（审查附录 C 第 3 条）：用假中继跑一遍真的回复流程。
/// 关掉「真人节奏」，不晚回、不犹豫；但「看到消息过一会儿才回」和分段的打字节奏照常，所以每个测试要等几秒
@MainActor
final class ChatEngineTests: XCTestCase {
    private var savedRoot: URL!
    private var tempRoot: URL!
    private var personas: [Persona] = []

    override func setUp() async throws {
        savedRoot = Storage.root
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("engine-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        Storage.root = tempRoot
        World.reload()
    }

    override func tearDown() async throws {
        for p in personas { UserDefaults.standard.removeObject(forKey: Prefs.human(.pace, p.id)) }
        personas = []
        World.clear()
        Thoughts.shared.clear()
        Storage.root = savedRoot
        World.reload()
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - 准备

    private struct Chat {
        let context: ModelContext
        let engine: ChatEngine
        let relay: FakeRelay
        let persona: Persona
        let convo: Conversation
    }

    private func makeChat() throws -> Chat {
        let schema = Schema(Schema1.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let persona = Persona(name: "TA")
        context.insert(persona)
        personas.append(persona)
        // 不晚回、不犹豫：结果才是确定的
        UserDefaults.standard.set(false, forKey: Prefs.human(.pace, persona.id))
        let convo = Conversation(isGroup: false, memberIDs: [persona.id])
        context.insert(convo)
        try context.save()
        let engine = ChatEngine()
        let relay = FakeRelay()
        engine.attach(relay: relay, banners: nil, router: nil)
        return Chat(context: context, engine: engine, relay: relay, persona: persona, convo: convo)
    }

    /// 等这一轮回复做完（最多 20 秒）
    private func waitUntilIdle(_ chat: Chat) async throws {
        let deadline = Date.now.addingTimeInterval(20)
        while chat.engine.isBusy(chat.convo) && Date.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(chat.engine.isBusy(chat.convo), "回复超时没结束")
    }

    private func replies(_ chat: Chat) -> [Message] {
        chat.convo.visibleMessages().filter { $0.role == .assistant }
    }

    private func assertSettled(_ chat: Chat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(chat.engine.typing[chat.convo.id], "「正在输入」要复原", file: file, line: line)
        XCTAssertTrue(chat.engine.buffers.isEmpty, "不能留着没收尾的气泡", file: file, line: line)
        XCTAssertFalse(replies(chat).contains { $0.status == .streaming }, "不能有一直在写的消息", file: file, line: line)
    }

    // MARK: - 测试

    func testReplySplitsIntoParagraphsAndResets() async throws {
        let chat = try makeChat()
        chat.relay.scripts = [[.text("在呢\n\n今天怎么样")]]
        chat.engine.send("在吗", in: chat.convo, members: [chat.persona], context: chat.context)
        XCTAssertTrue(chat.engine.isBusy(chat.convo))
        try await waitUntilIdle(chat)
        XCTAssertEqual(replies(chat).map(\.content), ["在呢", "今天怎么样"], "空一行就分成两条")
        XCTAssertTrue(replies(chat).allSatisfy { $0.status == .done })
        XCTAssertNotNil(chat.convo.visibleMessages().first { $0.role == .user }?.readAt, "TA 回了，你的消息要显示已读")
        XCTAssertEqual(chat.relay.requests.count, 1)
        assertSettled(chat)
    }

    func testMessagesWhileTypingAreAnsweredTogether() async throws {
        let chat = try makeChat()
        chat.relay.scripts = [[.text("两句都看到了")]]
        chat.engine.send("第一句", in: chat.convo, members: [chat.persona], context: chat.context)
        // TA 还没开口就又说了一句：重新看一遍、一起回，只回一次
        chat.engine.send("第二句", in: chat.convo, members: [chat.persona], context: chat.context)
        try await waitUntilIdle(chat)
        XCTAssertEqual(chat.relay.requests.count, 1, "插话以后只回一次")
        XCTAssertTrue(chat.relay.requests.first?.prompt.contains("第二句") == true, "TA 要看到后来说的那句")
        XCTAssertEqual(replies(chat).map(\.content), ["两句都看到了"])
        assertSettled(chat)
    }

    func testQueuedWhileDisconnectedIsAnsweredOnceAfterConnecting() async throws {
        let chat = try makeChat()
        chat.relay.isConnected = false
        chat.engine.send("你在吗", in: chat.convo, members: [chat.persona], context: chat.context)
        XCTAssertFalse(chat.engine.isBusy(chat.convo), "没连上时先不回")
        XCTAssertNotNil(chat.engine.notices[chat.convo.id], "告诉你连上后再回")
        XCTAssertTrue(chat.relay.requests.isEmpty)
        chat.relay.isConnected = true
        chat.engine.answerQueued(context: chat.context)
        // 连上的提醒可能来两次：第二次不能再回一遍
        chat.engine.answerQueued(context: chat.context)
        try await waitUntilIdle(chat)
        XCTAssertEqual(chat.relay.requests.count, 1, "连上以后只回一次")
        XCTAssertEqual(replies(chat).count, 1)
        assertSettled(chat)
    }

    func testFailureMarksErrorAndResets() async throws {
        let chat = try makeChat()
        chat.relay.scripts = [[]]
        chat.relay.failure = RelayError.server("电脑那边出错了")
        chat.engine.send("在吗", in: chat.convo, members: [chat.persona], context: chat.context)
        try await waitUntilIdle(chat)
        let reply = try XCTUnwrap(replies(chat).last)
        XCTAssertEqual(reply.status, .error)
        XCTAssertEqual(reply.errorText, "电脑那边出错了", "出错要留着原因")
        assertSettled(chat)
    }

    func testHaltStopsBeforeAsking() async throws {
        let chat = try makeChat()
        chat.engine.send("在吗", in: chat.convo, members: [chat.persona], context: chat.context)
        await chat.engine.halt(chat.convo.id)
        XCTAssertFalse(chat.engine.isBusy(chat.convo), "停下以后不再忙")
        XCTAssertTrue(chat.relay.requests.isEmpty, "还没开口就停了：不去问电脑")
        assertSettled(chat)
    }
}
