import SwiftUI

/// App 里所有存在本机的设置项都在这里登记，别处只用这里的名字，不直接写字符串
enum Prefs {
    // MARK: 我
    static let nickname = "nickname"

    // MARK: 模型
    static let defaultClaudeModel = "defaultClaudeModel"
    static let defaultCodexModel = "defaultCodexModel"
    static let defaultClaudeEffort = "defaultClaudeEffort"
    static let defaultCodexEffort = "defaultCodexEffort"
    static let showEngineLogo = "showEngineLogo"

    // MARK: 外观
    static let appearance = "appearance"
    static let wallpaper = "wallpaper"
    /// 聊天背景、我的头像、主页照片小组件换图时的标记，用来刷新缓存
    static let wallpaperStamp = "wallpaperStamp"
    static let myAvatarStamp = "myAvatarStamp"
    static let widgetPhotoStamp = "widgetPhotoStamp"
    static let homeWidgets = "homeWidgets"
    /// 上次看动态的时间：之后发的算「新的」
    static let momentsSeenAt = "momentsSeenAt"
    /// 动态小组件已经自动加到主页过一次（之后你删了就不再加）
    static let momentsWidgetAdded = "momentsWidgetAdded"

    // MARK: 聊天
    /// 上次键盘的高度：面板和键盘一样高，切换时不跳
    static let keyboardHeight = "keyboardHeight"
    /// 新建了但还没放表情的空表情包
    static let stickerPackOrder = "stickerPackOrder"
    static let recentSearches = "recentSearches"
    /// 你和 TA 的约定（到点来找你），见 Appointments
    static let appointments = "appointments"
    /// 决定不追问的那几条消息（聊天自然结束了）
    static let followUpSettled = "followUpSettled"
    /// MiniMax 用国内版（minimaxi.com）还是国际版（minimax.io）：两边的密钥不通用
    static let minimaxRegion = "minimaxRegion"
    /// 自己给声音起的名字（声音 ID → 名字，JSON）
    static let voiceNames = "voiceNames"

    // MARK: 日记与今日一句
    /// 谁来写 AI 日记（角色 ID）
    static let diaryWriter = "diaryWriter"
    /// 待办页是否显示「我」的日记
    static let showMyDiary = "showMyDiary"
    static let whisperDay = "whisperDay"
    static let whisperText = "whisperText"
    static let whisperAuthor = "whisperAuthor"

    // MARK: 通知
    static let inAppBanner = "inAppBanner"
    static let todoReminders = "todoReminders"
    static let diaryReminder = "diaryReminder"
    static let quietStart = "quietStart"
    static let quietEnd = "quietEnd"

    // MARK: 隐私与安全
    /// 打开 App 需要 Face ID
    static let appLock = "appLock"
    /// 让 TA 操作电脑前需要 Face ID
    static let workAuth = "workAuth"

    // MARK: 连接与备份
    static let relayAddress = "relayAddress"
    /// 不在家时用的地址（Tailscale）
    static let relayAddressAway = "relayAddressAway"
    static let lastBackupAt = "lastBackupAt"
    static let autoBackupToPC = "autoBackupToPC"
    /// 最近一次备份到电脑没成功的时间（成功一次就清掉），和没成功的原因
    static let backupFailedAt = "backupFailedAt"
    static let backupFailReason = "backupFailReason"
    /// 数据库升级失败时，旧数据库挪到了哪里
    static let lastStoreRescue = "lastStoreRescue"
    /// 你评论了动态、TA 当时没能回（电脑没连上）：连上以后补回
    static let momentPendingReplies = "momentPendingReplies"

    // MARK: 截图用的示例模式（启动参数 -demo YES -demoScreen chat）
    static let demo = "demo"
    static let demoScreen = "demoScreen"

    // MARK: - 读取

    static var nicknameValue: String { (UserDefaults.standard.string(forKey: nickname) ?? "").trimmed }

    static func defaultModel(for engine: Engine) -> String {
        UserDefaults.standard.string(forKey: engine == .claude ? defaultClaudeModel : defaultCodexModel) ?? ""
    }

    static func defaultEffort(for engine: Engine) -> String {
        UserDefaults.standard.string(forKey: engine == .claude ? defaultClaudeEffort : defaultCodexEffort) ?? ""
    }

    /// 免打扰时段（小时），默认 23:00–8:00
    static var quietHours: (Int, Int) {
        let d = UserDefaults.standard
        let s = d.object(forKey: quietStart) as? Int ?? 23
        let e = d.object(forKey: quietEnd) as? Int ?? 8
        return (s, e)
    }

    static func isQuiet(_ date: Date) -> Bool {
        let (s, e) = quietHours
        let h = Calendar.current.component(.hour, from: date)
        return s > e ? (h >= s || h < e) : (h >= s && h < e)
    }
}

enum Appearance: Int, CaseIterable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}
