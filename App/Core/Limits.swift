import Foundation

/// 业务数值（ARCH-9）：时间间隔、频率、窗口、截断长度、上限，按功能分组，改一处就行。
/// 界面的尺寸、颜色、动画不在这里（见 Theme）
enum Limits {
    /// 发给模型的提示词带多少东西（PROMPT-6）
    enum Prompt {
        /// 主动消息、追问、约定、交换日记这类轻请求带的最近聊天条数
        static let recentChat = 20
        /// 补一句、发动态时看的最近聊天条数
        static let shortChat = 16
        /// 写日记时一天里最多读的聊天条数
        static let diaryChat = 80
        /// 长期记忆最多多少字
        static let memory = 1500
        /// 记忆互通：别的聊天里记得的事每段最多带多少字
        static let sharedMemory = 500
        /// 一句心声最多多少字
        static let thought = 120
        /// 你的动态、日记写进提示词时每条截到多少字
        static let note = 160
        /// 今日一句、主动消息里带的今天待办最多几件
        static let todos = 5
    }

    /// 时间间隔
    enum Timing {
        /// App 开着时多久检查一次该做的事（日记、主动消息、动态…）
        static let refresh = Duration.seconds(600)
        /// 断线时正在进行的回复：这么久还连不上才判失败（电脑上还在继续生成，连上后接着收）
        static let orphanReply = Duration.seconds(90)
        /// 自动备份到电脑：隔多久一次；失败后隔多久再试
        static let autoBackup: TimeInterval = 20 * 3600
        static let backupRetry: TimeInterval = 2 * 3600
        /// 刷视频分享：隔多久最多一次
        static let videoShare: TimeInterval = 20 * 3600
        /// 天气：隔多久取一次；多旧就不再写进提示词
        static let weatherRefresh: TimeInterval = 3600
        static let weatherStale: TimeInterval = 3 * 3600
        /// 追问：只看 TA 最近这么久内发的最后一条
        static let followUpWindow: TimeInterval = 12 * 3600
        /// 约定：写好以后你们又聊过，离约定还有这么久以内时按新的聊天重写
        static let appointmentRewrite: TimeInterval = 6 * 3600
        /// 待办提醒只提前排这么久以内的（iOS 最多同时留 64 个待发通知）
        static let todoHorizon: TimeInterval = 14 * 24 * 3600
        /// 一起听：TA 插话至少隔这么久
        static let listenComment: TimeInterval = 360
    }

    /// 会一直增长的记录最多留多少（DATA-8）
    enum Store {
        /// 心声最多留多少条；超了按消息先后删到 thoughtsKeep 条
        static let thoughts = 3000
        static let thoughtsKeep = 2500
        /// 一起听过的歌最多记多少首
        static let listened = 200
        /// 每个角色记住哪些相册照片已经发过
        static let sentPhotos = 200
        /// 世界大事最多留多少件
        static let worldEvents = 60
        /// 决定不追问的消息最多记多少条
        static let followUpSettled = 40
    }

    /// 文件大小
    enum Files {
        /// 一次能发给 TA 的单个文件最大多少
        static let attachment = 20 * 1024 * 1024
    }
}
