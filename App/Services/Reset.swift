import SwiftUI
import SwiftData
import UserNotifications
import os

/// 设置最下面的三档重置，从轻到重：
/// 还原所有设置（只是偏好，数据都留着）→ 删除所有人设（角色和跟 TA 们有关的一切，换回默认的 Claude 和 Codex）
/// → 恢复出厂设置（什么都删，连和电脑的配对、语音服务的密钥也清掉，像刚装好一样）。
/// 要清哪些设置键、哪些小文件，都从登记表取（Prefs.registry、Storage.File），不在这里另写清单（DATA-7）
@MainActor
enum Reset {
    static func settings() {
        let d = UserDefaults.standard
        for key in Prefs.keys(clearedBy: .settings) { d.removeObject(forKey: key) }
        // 聊天背景：每个对话自己的选择、明暗和模糊，还有选过的照片
        for key in d.dictionaryRepresentation().keys where key.hasPrefix(Prefs.wallpaperPrefix) && key != Prefs.wallpaperStamp {
            d.removeObject(forKey: key)
        }
        WallpaperStore.removeAllPhotos()
    }

    /// 删到一半存不下（比如手机存储满了）时什么都不删，抛出 Cleanup.Failure，设置页告诉你没删成
    static func personas(context: ModelContext, engine: ChatEngine) async throws {
        var after = try await Cleanup.removeAllConversations(context: context, engine: engine)
        do {
            after.personas = try context.fetch(FetchDescriptor<Persona>()).map(\.id)
            try context.delete(model: Persona.self)
            try context.delete(model: DiaryEntry.self)
            try context.delete(model: MomentComment.self)
            try context.delete(model: Moment.self)
            try context.delete(model: AlbumPhoto.self)
        } catch {
            context.rollback()
            Log.store.error("删除所有人设没能做完，已撤销：\(error.localizedDescription, privacy: .public)")
            throw Cleanup.Failure()
        }
        try Cleanup.save(context)
        Cleanup.finish(after)
        let d = UserDefaults.standard
        for key in Prefs.keys(clearedBy: .personas) { d.removeObject(forKey: key) }
        for key in d.dictionaryRepresentation().keys where key.hasPrefix(Prefs.humanPrefix) { d.removeObject(forKey: key) }
        // 世界观里跟角色有关的（每个人的生活、关系、世界大事）一起清掉；你写的世界和「你是谁」留着
        World.forgetEveryone()
        ListenTogether.shared.stop()
        // 没有角色了：放回默认的 Claude 和 Codex
        Seeder.prepare(context)
    }

    static func everything(context: ModelContext, engine: ChatEngine, relay: RelayClient) async throws {
        let after = try await Cleanup.removeAllConversations(context: context, engine: engine)
        do {
            try context.delete(model: Persona.self)
            try context.delete(model: TodoItem.self)
            try context.delete(model: DiaryEntry.self)
            try context.delete(model: Sticker.self)
            try context.delete(model: MomentComment.self)
            try context.delete(model: Moment.self)
            try context.delete(model: AlbumPhoto.self)
        } catch {
            context.rollback()
            Log.store.error("恢复出厂没能做完，已撤销：\(error.localizedDescription, privacy: .public)")
            throw Cleanup.Failure()
        }
        try Cleanup.save(context)
        Cleanup.finish(after)

        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()

        // 存在本机的小文件：登记表里的全部、聊天背景、数据库升级失败时留下的旧库、临时文件
        ListenTogether.shared.stop()
        for file in Storage.File.allCases { Storage.remove(file) }
        WallpaperStore.removeAllPhotos()
        for name in Storage.names(prefix: Storage.rescuePrefix) { Storage.remove(name) }
        let fm = FileManager.default
        // 临时文件删不掉也没关系：系统会自己清
        for url in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
        // 内存里的也跟着清
        ImageFileStore.myAvatar.clear()
        ImageFileStore.widgetPhoto.clear()
        World.clear()
        Thoughts.shared.clear()
        VideoCards.shared.clear()
        CallLogs.shared.clear()
        ListenTogether.shared.reloadHistory()
        Books.shared.removeAll()

        // 钥匙串：和电脑的配对码、语音服务的密钥
        Keychain.delete(Keychain.Account.relayCode)
        for provider in VoiceProvider.allCases { Voice.setKey("", for: provider) }
        // 所有设置
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        // 地址清空了：断开连接，显示「未设置」
        relay.reconnect()

        Seeder.prepare(context)
    }
}
