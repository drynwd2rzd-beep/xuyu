import SwiftUI
import SwiftData
import UserNotifications

/// 设置最下面的三档重置，从轻到重：
/// 还原所有设置（只是偏好，数据都留着）→ 删除所有人设（角色和跟 TA 们有关的一切，换回默认的 Claude 和 Codex）
/// → 恢复出厂设置（什么都删，连和电脑的配对、语音服务的密钥也清掉，像刚装好一样）
@MainActor
enum Reset {
    /// 「设置」：外观、通知、默认模型、小组件、隐私、语音这些偏好。称呼和头像是「我」，不算设置
    private static let preferenceKeys = [
        Prefs.defaultClaudeModel, Prefs.defaultCodexModel, Prefs.defaultClaudeEffort, Prefs.defaultCodexEffort,
        Prefs.showEngineLogo, Prefs.appearance, Prefs.homeWidgets, Prefs.momentsWidgetAdded, Prefs.keyboardHeight,
        Prefs.minimaxRegion, Prefs.diaryWriter,
        Prefs.inAppBanner, Prefs.todoReminders, Prefs.diaryReminder, Prefs.quietStart, Prefs.quietEnd,
        Prefs.appLock, Prefs.workAuth, Prefs.autoBackupToPC,
    ]

    /// 跟角色有关、角色删掉后就没有意义的记录
    private static let personaKeys = [
        Prefs.diaryWriter, Prefs.whisperDay, Prefs.whisperText, Prefs.whisperAuthor, Prefs.momentsSeenAt,
        Prefs.appointments, Prefs.followUpSettled, Prefs.momentPendingReplies,
    ]

    static func settings() {
        let d = UserDefaults.standard
        for key in preferenceKeys { d.removeObject(forKey: key) }
        // 聊天背景：全局的选择、每个对话自己的选择、明暗和模糊，还有选过的照片
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("wallpaper") && key != Prefs.wallpaperStamp {
            d.removeObject(forKey: key)
        }
        WallpaperStore.removeAllPhotos()
    }

    static func personas(context: ModelContext, engine: ChatEngine) async {
        await clearConversations(context: context, engine: engine)
        try? context.delete(model: Persona.self)
        try? context.delete(model: DiaryEntry.self)
        try? context.delete(model: MomentComment.self)
        try? context.delete(model: Moment.self)
        try? context.delete(model: AlbumPhoto.self)
        for key in personaKeys { UserDefaults.standard.removeObject(forKey: key) }
        // 世界观里跟角色有关的（每个人的生活、关系、世界大事）一起清掉；你写的世界和「你是谁」留着
        var world = World.state
        world.lives = [:]
        world.relations = []
        world.events = []
        world.lastTurn = nil
        World.state = world
        context.persist()
        // 没有角色了：放回默认的 Claude 和 Codex
        Seeder.prepare(context)
    }

    static func everything(context: ModelContext, engine: ChatEngine, relay: RelayClient) async {
        await clearConversations(context: context, engine: engine)
        try? context.delete(model: Persona.self)
        try? context.delete(model: TodoItem.self)
        try? context.delete(model: DiaryEntry.self)
        try? context.delete(model: Sticker.self)
        try? context.delete(model: MomentComment.self)
        try? context.delete(model: Moment.self)
        try? context.delete(model: AlbumPhoto.self)
        context.persist()

        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()

        // 存在本机的图片：聊天背景、我的头像、照片小组件；数据库升级失败时留下的旧库；临时文件
        WallpaperStore.removeAllPhotos()
        MyAvatarStore.clear()
        WidgetPhotoStore.clear()
        World.clear()
        Thoughts.shared.clear()
        Books.shared.removeAll()
        VideoCards.shared.clear()
        CallLogs.shared.clear()
        ListenTogether.shared.stop()
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for url in (try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("数据库备份-") {
            try? fm.removeItem(at: url)
        }
        for url in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }

        // 钥匙串：和电脑的配对码、语音服务的密钥
        Keychain.delete("relayCode")
        for provider in VoiceProvider.allCases { Voice.setKey("", for: provider) }
        // 所有设置
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        // 地址清空了：断开连接，显示「未设置」
        relay.reconnect()

        Seeder.prepare(context)
    }

    /// 先停下正在回复的、撤掉提前排好的主动消息通知，等收好尾再删（不然还会往删掉的聊天里写）
    private static func clearConversations(context: ModelContext, engine: ChatEngine) async {
        let convos = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        for c in convos {
            engine.stop(c)
            for m in c.plannedMessages() { Reminders.cancelProactive(messageID: m.id) }
        }
        try? await Task.sleep(for: .milliseconds(350))
        for c in convos { WallpaperStore.remove(for: c.id) }
        try? context.delete(model: Attachment.self)
        try? context.delete(model: Message.self)
        try? context.delete(model: Conversation.self)
    }
}
