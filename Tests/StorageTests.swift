import XCTest
import SwiftData
@testable import Xuyu

/// 本机小文件、设置登记表、备份字段：坏了不清空、类型不丢、字段不漏（DATA-2、DATA-6、DATA-7）
@MainActor
final class StorageTests: XCTestCase {
    private var savedRoot: URL!
    private var tempRoot: URL!

    override func setUp() async throws {
        savedRoot = Storage.root
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("storage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        Storage.root = tempRoot
    }

    override func tearDown() async throws {
        Storage.root = savedRoot
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - 坏文件

    func testBrokenFileIsKeptAside() throws {
        let file = Storage.url(.world)
        try Data("不是 JSON".utf8).write(to: file)
        XCTAssertNil(Storage.read(World.State.self, from: .world))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "坏文件已经挪走，下次写入不会盖掉它")
        let broken = file.appendingPathExtension("broken")
        XCTAssertEqual(try Data(contentsOf: broken), Data("不是 JSON".utf8))
        // 没有文件时只是空的，不算坏
        XCTAssertNil(Storage.read(World.State.self, from: .world))
    }

    func testWorldKeepsDefaultsForMissingFields() throws {
        // 以前的 world.json 里没有后来加的项：用默认值，不会整份读不出来
        let old = Data(#"{"world":"海边小镇","you":"","relations":[{"a":null,"b":null,"text":"老朋友"}],"lives":[],"events":[]}"#.utf8)
        let state = try JSONDecoder().decode(World.State.self, from: old)
        XCTAssertEqual(state.world, "海边小镇")
        XCTAssertEqual(state.relations.first?.text, "老朋友")
        XCTAssertTrue(state.lifeOn)
        XCTAssertTrue(state.eventsOn)
    }

    func testAppointmentKeepsDefaultsForMissingFields() throws {
        let id = UUID()
        let old = Data(#"[{"personaID":"\#(id.uuidString)","conversationID":"\#(id.uuidString)","what":"催睡觉","at":0}]"#.utf8)
        let list = try JSONDecoder().decode([Appointment].self, from: old)
        XCTAssertEqual(list.first?.what, "催睡觉")
        XCTAssertEqual(list.first?.daily, false)
    }

    func testKeyedStoreRoundTripAndRemove() {
        let store = KeyedFileStore<String>(.thoughts)
        let a = UUID(), b = UUID()
        store.set("其实有点想你", for: a)
        store.set("装作不在意", for: b)
        // 文件格式和以前一样，重新读出来还在
        let again = KeyedFileStore<String>(.thoughts)
        XCTAssertEqual(again.value(a), "其实有点想你")
        again.remove([a])
        XCTAssertNil(KeyedFileStore<String>(.thoughts).value(a))
        again.keep(only: [])
        XCTAssertEqual(KeyedFileStore<String>(.thoughts).count, 0)
    }

    // MARK: - 设置登记表

    func testPrefsRegistryRestoresByType() throws {
        XCTAssertEqual(Set(Prefs.registry.map(\.key)).count, Prefs.registry.count, "同一个键登记了两次")
        func entry(_ key: String) throws -> Prefs.Entry { try XCTUnwrap(Prefs.registry.first { $0.key == key }) }
        // 称呼填的是数字，恢复后仍然是文字
        XCTAssertEqual(try entry(Prefs.nickname).value(from: "520") as? String, "520")
        XCTAssertEqual(try entry(Prefs.inAppBanner).value(from: "1") as? Bool, true)
        XCTAssertEqual(try entry(Prefs.inAppBanner).value(from: "0") as? Bool, false)
        XCTAssertEqual(try entry(Prefs.quietStart).value(from: "23") as? Int, 23)
        XCTAssertNil(try entry(Prefs.quietStart).value(from: "晚上"))
        XCTAssertTrue(Prefs.keys(clearedBy: .settings).contains(Prefs.appearance))
        XCTAssertTrue(Prefs.keys(clearedBy: .personas).contains(Prefs.appointments))
        XCTAssertFalse(Prefs.keys(clearedBy: .settings).contains(Prefs.nickname))
    }

    // MARK: - 备份字段

    /// 每个数据库模型的每个字段都进了备份（不进的写明理由）：以后加字段漏了备份，这里会红
    func testBackupCoversEveryField() {
        let notBackedUp: [String: Set<String>] = [
            // 正在生成的回复不备份，取回中断回复用的编号也就不用备份；conversation 是反向关系
            "Message": ["relayID", "conversation"],
            // 附件的编号没有别处用到；message 是反向关系
            "Attachment": ["id", "message"],
            "MomentComment": ["moment"],
        ]
        let records: [String: Any] = [
            "Persona": Backup.PersonaDTO(Persona(name: "TA")),
            "Conversation": Backup.ConversationDTO(Conversation(isGroup: false, memberIDs: [])),
            "Message": Backup.MessageDTO(Message(role: .user, content: "")),
            "Attachment": Backup.AttachmentDTO(Attachment(kind: .image, fileName: "a.jpg", data: Data(), order: 0)),
            "TodoItem": Backup.TodoDTO(TodoItem(title: "")),
            "DiaryEntry": Backup.DiaryDTO(DiaryEntry(day: .now, author: .me, text: "")),
            "Sticker": Backup.StickerDTO(Sticker(pack: "", data: Data())),
            "Moment": Backup.MomentDTO(Moment(personaID: nil, text: "")),
            "MomentComment": Backup.CommentDTO(MomentComment(personaID: nil, text: "")),
            "AlbumPhoto": Backup.AlbumDTO(AlbumPhoto(personaID: nil, data: Data())),
        ]
        for entity in Schema(Schema1.models).entities {
            guard let record = records[entity.name] else {
                XCTFail("\(entity.name) 没有进备份")
                continue
            }
            let fields = Set(entity.attributes.map(\.name) + entity.relationships.map(\.name))
            let saved = Set(Mirror(reflecting: record).children.compactMap(\.label))
            XCTAssertEqual(fields.subtracting(saved).subtracting(notBackedUp[entity.name] ?? []), [], "\(entity.name) 有字段没进备份")
        }
    }

    // MARK: - 备份再恢复，内容一样

    private func makeContext() throws -> ModelContext {
        let schema = Schema(Schema1.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    func testBackupRoundTrip() async throws {
        let defaults = UserDefaults.standard
        let savedNickname = defaults.object(forKey: Prefs.nickname)
        defer { defaults.set(savedNickname, forKey: Prefs.nickname) }

        let source = try makeContext()
        let persona = Persona(name: "TA", systemPrompt: "温柔")
        persona.followUp = 2
        persona.lang = .ko
        source.insert(persona)
        let convo = Conversation(isGroup: false, memberIDs: [persona.id])
        convo.memory = "喜欢火锅"
        source.insert(convo)
        let now = Date.now
        let asked = Message(role: .user, content: "吃火锅吗")
        asked.createdAt = now.addingTimeInterval(-5)
        asked.readAt = now
        convo.add(asked, context: source)
        let answer = Message(role: .assistant, content: "好呀", personaID: persona.id)
        answer.createdAt = now
        answer.quote = "你：吃火锅吗"
        answer.quoteID = asked.id
        convo.add(answer, context: source)
        let voice = Attachment(kind: .audio, fileName: "voice.mp3", data: Data([1, 2]), order: 0)
        voice.message = answer
        source.insert(voice)
        source.insert(TodoItem(title: "买菜"))
        source.insert(DiaryEntry(day: now.startOfDay, author: .me, text: "今天很开心", mood: "开心"))
        source.insert(Sticker(pack: "猫猫", data: Data([7])))
        let moment = Moment(personaID: persona.id, text: "桂花开了")
        source.insert(moment)
        moment.add(MomentComment(personaID: nil, text: "好香"), context: source)
        source.insert(AlbumPhoto(personaID: persona.id, data: Data([9])))
        try source.save()
        // 每个角色的真人感设置、称呼、小文件也一起备份
        let moodKey = Prefs.human(.mood, persona.id)
        defaults.set(2, forKey: moodKey)
        defaults.set("520", forKey: Prefs.nickname)
        Thoughts.shared.set("其实有点想你", for: answer.id)

        let data = try Backup.export(context: source)
        defaults.removeObject(forKey: moodKey)
        defaults.removeObject(forKey: Prefs.nickname)
        Thoughts.shared.clear()
        let target = try makeContext()
        try await Backup.restore(data, context: target)

        let personas = try target.fetch(FetchDescriptor<Persona>())
        XCTAssertEqual(personas.map(\.name), ["TA"])
        XCTAssertEqual(personas.first?.followUp, 2)
        XCTAssertEqual(personas.first?.lang, .ko)
        let convos = try target.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(convos.first?.memory, "喜欢火锅")
        let messages = convos.first?.visibleMessages() ?? []
        XCTAssertEqual(messages.map(\.content), ["吃火锅吗", "好呀"])
        XCTAssertNotNil(messages.first?.readAt)
        XCTAssertEqual(messages.last?.quoteID, asked.id)
        XCTAssertEqual(messages.last?.sortedAttachments.first?.kind, .audio)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<TodoItem>()), 1)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<DiaryEntry>()), 1)
        XCTAssertEqual(try target.fetch(FetchDescriptor<Sticker>()).first?.pack, "猫猫")
        XCTAssertEqual(try target.fetch(FetchDescriptor<Moment>()).first?.comments?.first?.text, "好香")
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<AlbumPhoto>()), 1)
        XCTAssertEqual(defaults.integer(forKey: moodKey), 2)
        XCTAssertEqual(defaults.string(forKey: Prefs.nickname), "520")
        XCTAssertEqual(Thoughts.shared.text(answer.id), "其实有点想你")
        defaults.removeObject(forKey: moodKey)
        Thoughts.shared.clear()
    }
}
