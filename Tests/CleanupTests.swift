import XCTest
import SwiftData
@testable import Xuyu

/// 删除和清空之后什么都不剩（CONC-9）：清空聊天留着记忆，删角色把 TA 的东西都清掉
@MainActor
final class CleanupTests: XCTestCase {
    private var savedRoot: URL!
    private var tempRoot: URL!

    override func setUp() async throws {
        savedRoot = Storage.root
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        Storage.root = tempRoot
        World.reload()
    }

    override func tearDown() async throws {
        World.clear()
        Thoughts.shared.clear()
        Storage.root = savedRoot
        World.reload()
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(Schema1.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    private func say(_ text: String, by persona: Persona?, in convo: Conversation, at date: Date = .now, context: ModelContext) -> Message {
        let m = Message(role: persona == nil ? .user : .assistant, content: text, personaID: persona?.id)
        m.createdAt = date
        convo.add(m, context: context)
        return m
    }

    func testClearChatKeepsMemory() async throws {
        let context = try makeContext()
        let engine = ChatEngine()
        let persona = Persona(name: "TA")
        context.insert(persona)
        let convo = Conversation(isGroup: false, memberIDs: [persona.id])
        convo.memory = "喜欢火锅"
        context.insert(convo)
        let said = say("好呀", by: persona, in: convo, context: context)
        // 排好、还没到点的那条也要撤掉
        say("在干嘛呀", by: persona, in: convo, at: .now.addingTimeInterval(3600), context: context).isProactive = true
        try context.save()
        Thoughts.shared.set("其实有点想你", for: said.id)

        await Cleanup.clearChat(convo, context: context, engine: engine)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Message>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 1)
        XCTAssertEqual(convo.memory, "喜欢火锅", "清空聊天只清记录，记忆留着")
        XCTAssertNil(Thoughts.shared.text(said.id))
    }

    func testDeletePersonaLeavesNothingBehind() async throws {
        let context = try makeContext()
        let engine = ChatEngine()
        let gone = Persona(name: "要删的")
        let stay = Persona(name: "留下的")
        context.insert(gone)
        context.insert(stay)
        let single = context.chat(for: gone)
        let group = Conversation(title: "三个人", isGroup: true, memberIDs: [gone.id, stay.id])
        let alone = Conversation(title: "只有 TA", isGroup: true, memberIDs: [gone.id])
        context.insert(group)
        context.insert(alone)
        let said = say("你好", by: gone, in: single, context: context)
        _ = say("大家好", by: gone, in: group, context: context)
        // TA 提前排好、还没到点的那条（计划消息都标着 isProactive）
        say("晚点见", by: gone, in: group, at: .now.addingTimeInterval(3600), context: context).isProactive = true
        context.insert(AlbumPhoto(personaID: gone.id, data: Data([1])))
        context.insert(AlbumPhoto(personaID: nil, data: Data([2])))
        let theirs = Moment(personaID: gone.id, text: "桂花开了")
        context.insert(theirs)
        let mine = Moment(personaID: nil, text: "今天好累")
        mine.likedBy = [gone.id, stay.id]
        context.insert(mine)
        mine.add(MomentComment(personaID: gone.id, text: "抱抱"), context: context)
        let diary = DiaryEntry(day: .now, author: .ai, text: "今天和你聊了很多")
        diary.personaID = gone.id
        context.insert(diary)
        try context.save()
        Thoughts.shared.set("其实有点想你", for: said.id)
        let key = Prefs.human(.mood, gone.id)
        UserDefaults.standard.set(2, forKey: key)
        var world = World.state
        world.relations = [World.Relation(a: gone.id, b: nil, text: "老朋友"), World.Relation(a: stay.id, b: nil, text: "同事")]
        world.lives = [gone.id: World.Life(role: "记者"), stay.id: World.Life(role: "老师")]
        World.state = world

        await Cleanup.deletePersona(gone, context: context, engine: engine)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Persona>()).map(\.name), ["留下的"])
        let convos = try context.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(convos.map(\.title), ["三个人"], "TA 的单聊、只剩 TA 的群都删掉")
        XCTAssertEqual(convos.first?.memberIDs, [stay.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Message>()).map(\.content), ["大家好"], "TA 在群里说过的话留着，没到点的撤掉")
        XCTAssertEqual(try context.fetch(FetchDescriptor<AlbumPhoto>()).map(\.personaID), [nil])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Moment>()).map(\.text), ["今天好累"])
        XCTAssertEqual(mine.likedBy, [stay.id])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MomentComment>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DiaryEntry>()), 0)
        XCTAssertNil(Thoughts.shared.text(said.id))
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        XCTAssertEqual(World.state.relations.map(\.text), ["同事"])
        XCTAssertNil(World.state.lives[gone.id])
        XCTAssertNotNil(World.state.lives[stay.id])
    }
}
