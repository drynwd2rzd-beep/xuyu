import os

/// 统一的日志（ERR-4）：按功能分类别。连上 Mac 打开「控制台」，按 subsystem「app.xuyu.ios」筛选就能看到。
/// 只记「哪一步、出了什么错」：不写聊天全文、配对码、密钥
enum Log {
    private static let subsystem = "app.xuyu.ios"
    /// 数据库和本机小文件：打开、保存、读坏了、写不进去
    static let store = Logger(subsystem: subsystem, category: "store")
    /// 和电脑中继的连接
    static let relay = Logger(subsystem: subsystem, category: "relay")
    /// 备份和恢复
    static let backup = Logger(subsystem: subsystem, category: "backup")
    /// 语音合成、通话
    static let voice = Logger(subsystem: subsystem, category: "voice")
    /// 自己动起来的事：主动消息、追问、日记、动态、视频分享、世界安排、天气。失败时不打扰你，只在这里记一笔
    static let auto = Logger(subsystem: subsystem, category: "auto")
}
