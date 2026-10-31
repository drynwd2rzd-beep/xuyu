import SwiftUI

/// App 里所有存在本机的设置项都在这里登记，别处只用这里的名字，不直接写字符串。
/// 每个键还要在下面的登记表 registry 里写一行：什么类型、进不进备份、哪一档重置会清掉它（DATA-7）
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

    // MARK: 天气（见 Weather）
    /// 打开「真实天气」（默认开）
    static let weatherEnabled = "weather.enabled"
    /// 自己填的城市（留空就用定位）
    static let weatherCity = "weather.city"
    /// 取到的天气：写进提示词的那段、设置里显示的一行、取的时间
    static let weatherSummary = "weather.summary"
    static let weatherPlace = "weather.place"
    static let weatherFetchedAt = "weather.fetchedAt"

    // MARK: 视频分享
    /// 上次有角色分享视频的时间：一天最多一次
    static let videoLastShare = "video.lastShare"

    // MARK: 截图用的示例模式（启动参数 -demo YES -demoScreen chat）
    static let demo = "demo"
    static let demoScreen = "demoScreen"

    // MARK: - 按对象生成的键

    /// 每个角色自己的设置和小记录（按角色 ID 生成键名，见 HumanTouch）。删角色时全部清掉，「删除所有人设」按前缀清
    enum Human: String, CaseIterable {
        /// 真人节奏（Bool，默认开）
        case pace
        /// 小情绪（Int：0 不要、1 一点点、2 明显，默认 1）
        case mood
        /// 内心想法（Bool，默认关）
        case thoughts
        /// 刷视频分享（Bool，默认开）
        case videos
        /// TA 对你的称呼、闹别扭（JSON）
        case relation
        /// 已经在聊天里发过的相册照片（字符串数组）
        case sentPhotos
    }

    static let humanPrefix = "human."

    static func human(_ key: Human, _ id: UUID) -> String { "\(humanPrefix)\(key.rawValue).\(id.uuidString)" }

    /// 聊天背景的键都以 wallpaper 开头：对话自己的选择（-1 跟随全局）、照片的明暗和模糊。「还原所有设置」按前缀清
    static let wallpaperPrefix = "wallpaper"

    static func wallpaperOf(_ owner: UUID) -> String { "wallpaper.\(owner.uuidString)" }
    static func wallpaperDimOf(_ owner: UUID?) -> String { owner.map { "wallpaperDim.\($0.uuidString)" } ?? "wallpaperDim" }
    static func wallpaperBlurOf(_ owner: UUID?) -> String { owner.map { "wallpaperBlur.\($0.uuidString)" } ?? "wallpaperBlur" }

    // MARK: - 登记表（DATA-7）

    /// 存的是什么类型：备份里的设置都存成文字，恢复时按它还原（不能看着像数字就存成数字，称呼填「520」也是文字）
    enum Kind { case string, int, double, bool }

    /// 三档重置里哪几档会清掉它；「恢复出厂设置」什么都清，不用写
    struct Clears: OptionSet {
        let rawValue: Int
        /// 还原所有设置
        static let settings = Clears(rawValue: 1)
        /// 删除所有人设
        static let personas = Clears(rawValue: 2)
    }

    struct Entry {
        let key: String
        let kind: Kind
        /// 跟着备份走
        let backup: Bool
        let clears: Clears

        /// 把备份里的文字按类型还原；对不上类型的不恢复
        func value(from text: String) -> Any? {
            switch kind {
            case .string: return text
            case .int: return Int(text)
            case .double: return Double(text)
            case .bool:
                // 以前的备份里布尔值写成「1」「0」
                if ["1", "true"].contains(text) { return true }
                if ["0", "false"].contains(text) { return false }
                return nil
            }
        }
    }

    /// 每个固定的键一行。新加键时必须加在这里（测试会检查 Prefs 里每个键都登记了）
    static let registry: [Entry] = [
        Entry(key: nickname, kind: .string, backup: true, clears: []),
        Entry(key: defaultClaudeModel, kind: .string, backup: true, clears: .settings),
        Entry(key: defaultCodexModel, kind: .string, backup: true, clears: .settings),
        Entry(key: defaultClaudeEffort, kind: .string, backup: true, clears: .settings),
        Entry(key: defaultCodexEffort, kind: .string, backup: true, clears: .settings),
        Entry(key: showEngineLogo, kind: .bool, backup: true, clears: .settings),
        Entry(key: appearance, kind: .int, backup: true, clears: .settings),
        Entry(key: wallpaper, kind: .int, backup: true, clears: .settings),
        Entry(key: wallpaperStamp, kind: .double, backup: false, clears: []),
        Entry(key: myAvatarStamp, kind: .double, backup: false, clears: []),
        Entry(key: widgetPhotoStamp, kind: .double, backup: false, clears: []),
        Entry(key: homeWidgets, kind: .string, backup: true, clears: .settings),
        Entry(key: momentsSeenAt, kind: .double, backup: false, clears: .personas),
        Entry(key: momentsWidgetAdded, kind: .bool, backup: false, clears: .settings),
        Entry(key: keyboardHeight, kind: .double, backup: false, clears: .settings),
        Entry(key: stickerPackOrder, kind: .string, backup: true, clears: []),
        Entry(key: recentSearches, kind: .string, backup: false, clears: []),
        Entry(key: appointments, kind: .string, backup: true, clears: .personas),
        Entry(key: followUpSettled, kind: .string, backup: false, clears: .personas),
        Entry(key: minimaxRegion, kind: .string, backup: true, clears: .settings),
        Entry(key: voiceNames, kind: .string, backup: true, clears: []),
        Entry(key: diaryWriter, kind: .string, backup: true, clears: [.settings, .personas]),
        Entry(key: whisperDay, kind: .string, backup: false, clears: .personas),
        Entry(key: whisperText, kind: .string, backup: false, clears: .personas),
        Entry(key: whisperAuthor, kind: .string, backup: false, clears: .personas),
        Entry(key: inAppBanner, kind: .bool, backup: true, clears: .settings),
        Entry(key: todoReminders, kind: .bool, backup: true, clears: .settings),
        Entry(key: diaryReminder, kind: .bool, backup: true, clears: .settings),
        Entry(key: quietStart, kind: .int, backup: true, clears: .settings),
        Entry(key: quietEnd, kind: .int, backup: true, clears: .settings),
        Entry(key: appLock, kind: .bool, backup: false, clears: .settings),
        Entry(key: workAuth, kind: .bool, backup: false, clears: .settings),
        Entry(key: relayAddress, kind: .string, backup: false, clears: []),
        Entry(key: relayAddressAway, kind: .string, backup: false, clears: []),
        Entry(key: lastBackupAt, kind: .double, backup: false, clears: []),
        Entry(key: autoBackupToPC, kind: .bool, backup: false, clears: .settings),
        Entry(key: backupFailedAt, kind: .double, backup: false, clears: []),
        Entry(key: backupFailReason, kind: .string, backup: false, clears: []),
        Entry(key: lastStoreRescue, kind: .string, backup: false, clears: []),
        Entry(key: momentPendingReplies, kind: .string, backup: false, clears: .personas),
        Entry(key: weatherEnabled, kind: .bool, backup: true, clears: .settings),
        Entry(key: weatherCity, kind: .string, backup: true, clears: .settings),
        Entry(key: weatherSummary, kind: .string, backup: false, clears: .settings),
        Entry(key: weatherPlace, kind: .string, backup: false, clears: .settings),
        Entry(key: weatherFetchedAt, kind: .double, backup: false, clears: .settings),
        Entry(key: videoLastShare, kind: .double, backup: false, clears: []),
        Entry(key: demo, kind: .bool, backup: false, clears: []),
        Entry(key: demoScreen, kind: .string, backup: false, clears: []),
    ]

    /// 跟着备份走的设置
    static var backedUp: [Entry] { registry.filter(\.backup) }

    /// 这一档重置要清掉的键（按前缀清的另算：还原设置清 wallpaper…，删除所有人设清 human.…）
    static func keys(clearedBy level: Clears) -> [String] {
        registry.filter { $0.clears.contains(level) }.map(\.key)
    }

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

    /// 同样的选择给 UIKit 窗口用（锁屏在单独的窗口里，不会继承 SwiftUI 的设置）
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
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
