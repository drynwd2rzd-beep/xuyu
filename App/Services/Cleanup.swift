import Foundation
import SwiftData
import SwiftUI
import os

/// 删除和清空的统一入口（CONC-9）：删消息、清空聊天、删群、删角色都走这里，「删除所有人设」「恢复出厂」也用这里的步骤（见 Reset）。
/// 顺序固定：
/// 1. 停下对话里的一切：回复、晚回、回拍、记忆整理、补一句（ChatEngine.halt，等正在写的真正收好尾）
/// 2. 删数据库里的东西，存盘。存盘失败就整个撤销：数据原样留着，提示没删成
/// 3. 存盘成功以后才清数据库外面的：待发和已弹出的通知、约定、心声 / 视频卡片 / 通话内容、背景、角色的小设置、世界观
@MainActor
enum Cleanup {
    /// 删除没能存下（比如手机存储满了）
    struct Failure: LocalizedError {
        var errorDescription: String? { String(localized: "没能全部删除，请再试一次。") }
    }

    // MARK: - 给界面用的入口（失败时屏幕上方提示「没能保存」）

    /// 删掉几条消息（长按删除、多选删除、编辑时拿掉原话）
    static func deleteMessages(_ messages: [Message], context: ModelContext) {
        var after = After()
        for m in messages {
            after.messages.append(m.id)
            context.delete(m)
        }
        report { try commit(after, context: context) }
    }

    /// 清空聊天：只清聊天记录，记忆留着（你在 Q-28 定的）。排好还没到点的消息、约定、通知一起撤；之后 TA 照常主动找你
    static func clearChat(_ convo: Conversation, context: ModelContext, engine: ChatEngine) async {
        await engine.halt(convo.id)
        var after = After()
        withAnimation(Motion.spring) { clearMessages(of: convo, context: context, into: &after) }
        report { try commit(after, context: context) }
    }

    /// 删群：群和里面的记录都删掉
    static func deleteGroup(_ convo: Conversation, context: ModelContext, engine: ChatEngine) async {
        await engine.halt(convo.id)
        var after = After()
        withAnimation(Motion.spring) { removeConversation(convo, context: context, into: &after) }
        report { try commit(after, context: context) }
    }

    /// 删角色：和 TA 有关的都清（你在 Q-28 定的）——单聊和记忆、约定、TA 的相册照片、动态和评论、TA 写的日记、
    /// 世界观里的关系和生活、TA 的小设置、心声 / 视频卡片 / 通话内容；正和 TA 一起听就停下，一起读的书不再算 TA 的。
    /// TA 在群里说过的话留着；群里一个人都不剩了就把群也删掉
    static func deletePersona(_ persona: Persona, context: ModelContext, engine: ChatEngine) async {
        let id = persona.id
        let convos = conversations(of: id, context: context)
        for c in convos { await engine.halt(c.id) }
        var after = After()
        after.personas.append(id)
        for c in convos {
            if c.isGroup {
                // TA 排好还没到点的消息撤掉
                for m in c.plannedMessages() where m.personaID == id {
                    after.messages.append(m.id)
                    context.delete(m)
                }
                c.memberIDs.removeAll { $0 == id }
                if c.memberIDs.isEmpty { removeConversation(c, context: context, into: &after) }
            } else {
                removeConversation(c, context: context, into: &after)
            }
        }
        removeBelongings(of: id, context: context)
        context.delete(persona)
        report { try commit(after, context: context) }
    }

    // MARK: - 给 Reset 用的步骤

    /// 删除所有人设、恢复出厂：所有对话都停下、删掉。存盘由 Reset 统一做，成功后再调 finish
    static func removeAllConversations(context: ModelContext, engine: ChatEngine) async throws -> After {
        let convos = try context.fetch(FetchDescriptor<Conversation>())
        for c in convos { await engine.halt(c.id) }
        var after = After()
        for c in convos { removeConversation(c, context: context, into: &after) }
        return after
    }

    /// 存盘：失败就撤销这次的全部改动，记日志，抛出 Failure
    static func save(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            Log.store.error("删除没能存下，已撤销：\(error.localizedDescription, privacy: .public)")
            throw Failure()
        }
    }

    // MARK: - 存盘成功以后才做的

    /// 数据库外面要一起清的东西，攒到存盘成功以后再清（存盘失败就都不动）
    struct After {
        /// 删掉的消息：待发通知、心声、视频卡片、通话内容
        var messages: [UUID] = []
        /// 清空或删掉的对话：已经弹出的通知、约定
        var conversations: [UUID] = []
        /// 整个删掉的对话：聊天背景
        var removed: [UUID] = []
        /// 删掉的角色：约定、小设置、世界观、一起听、一起读
        var personas: [UUID] = []
    }

    static func finish(_ after: After) {
        Reminders.cancelProactive(messageIDs: after.messages)
        Thoughts.shared.remove(after.messages)
        VideoCards.shared.remove(after.messages)
        CallLogs.shared.remove(after.messages)
        Reminders.removeDelivered(conversations: Set(after.conversations))
        for id in after.conversations { Appointments.removeAll(in: id) }
        for id in after.removed { WallpaperStore.remove(for: id) }
        for id in after.personas {
            Appointments.removeAll(by: id)
            for key in Prefs.Human.allCases { UserDefaults.standard.removeObject(forKey: Prefs.human(key, id)) }
            if UserDefaults.standard.string(forKey: Prefs.diaryWriter) == id.uuidString {
                UserDefaults.standard.removeObject(forKey: Prefs.diaryWriter)
            }
            World.forget(personaID: id)
            ListenTogether.shared.stop(ifWith: id)
            Books.shared.forget(personaID: id)
        }
    }

    // MARK: - 心声的上限

    /// 记下一句心声。超过上限时按消息先后删最早的（以前是随机删，刚写的也可能被删掉）；消息已经不在的先删
    static func saveThought(_ text: String, for id: UUID, context: ModelContext) {
        Thoughts.shared.set(text, for: id)
        guard Thoughts.shared.count > Limits.Store.thoughts else { return }
        let ids = Array(Thoughts.shared.values.keys)
        // 读不出来就这次先不删，下次再说（只是多留几条）
        guard let messages = try? context.fetch(FetchDescriptor<Message>(predicate: #Predicate { ids.contains($0.id) })) else { return }
        let newest = messages.sorted { $0.createdAt > $1.createdAt }.prefix(Limits.Store.thoughtsKeep).map(\.id)
        Thoughts.shared.keep(only: Set(newest))
    }

    // MARK: - 内部步骤

    private static func commit(_ after: After, context: ModelContext) throws {
        try save(context)
        finish(after)
    }

    private static func report(_ work: () throws -> Void) {
        do { try work() } catch { SaveAlert.shared.report() }
    }

    /// 这个角色在的所有对话（单聊和群聊）
    private static func conversations(of id: UUID, context: ModelContext) -> [Conversation] {
        // 读不出来就当没有：后面删角色本身仍会存盘，失败会提示
        let all = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        return all.filter { $0.memberIDs.contains(id) }
    }

    private static func clearMessages(of convo: Conversation, context: ModelContext, into after: inout After) {
        for m in convo.messages ?? [] {
            after.messages.append(m.id)
            context.delete(m)
        }
        after.conversations.append(convo.id)
    }

    private static func removeConversation(_ convo: Conversation, context: ModelContext, into after: inout After) {
        clearMessages(of: convo, context: context, into: &after)
        after.removed.append(convo.id)
        context.delete(convo)
    }

    /// TA 的相册照片、TA 发的动态（连同下面的评论）、TA 在别的动态下的评论和点赞、TA 写的日记、TA 给你日记的回信
    private static func removeBelongings(of id: UUID, context: ModelContext) {
        // 读不出来的那一类就先留着（只是删得不彻底，不会删多）
        for photo in (try? context.fetch(FetchDescriptor<AlbumPhoto>())) ?? [] where photo.personaID == id {
            context.delete(photo)
        }
        for moment in (try? context.fetch(FetchDescriptor<Moment>())) ?? [] {
            if moment.personaID == id {
                context.delete(moment)
                continue
            }
            moment.likedBy.removeAll { $0 == id }
            for c in moment.comments ?? [] where c.personaID == id { context.delete(c) }
        }
        for entry in (try? context.fetch(FetchDescriptor<DiaryEntry>())) ?? [] {
            if entry.author == .ai && entry.personaID == id {
                context.delete(entry)
            } else if entry.replyPersonaID == id {
                entry.reply = ""
                entry.replyPersonaID = nil
                entry.repliedText = ""
            }
        }
    }
}
