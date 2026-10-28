import Foundation

/// 一个角色的其余声音设置，和官网能调的一一对应。存在 Persona.voiceStyle 里（JSON），缺的项用默认值
struct VoiceStyle: Codable, Equatable {
    // MiniMax 音色微调（-100～100，0 = 原声）
    /// 低沉 ↔ 明亮
    var tonePitch = 0
    /// 有力 ↔ 柔和
    var intensity = 0
    /// 浑厚 ↔ 清脆
    var timbre = 0
    /// 音效：空 = 无；spacious_echo、auditorium_echo、lofi_telephone、robotic
    var effect = ""
    /// 语言增强：空 = 跟着「语音语言」；auto = 让模型自己判断
    var languageBoost = ""
    /// 朗读优化：数字、符号读得更准（稍慢一点）
    var quality = false
    /// 读音纠正，每条「原文/读音」，比如「重庆/(chong2)(qing4)」
    var pronunciations: [String] = []
    /// 混合声音：主声音的比重，和最多 3 个别的声音
    var mainWeight = 100
    var mixes: [Mix] = []

    // ElevenLabs（0～1）
    var stability = 0.45
    var similarity = 0.8
    var style = 0.3
    var speakerBoost = true

    struct Mix: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var weight: Int
    }

    init() {}

    /// 旧版本存的、或者以后加了新项：缺什么就用默认值，不会读坏
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VoiceStyle()
        tonePitch = try c.decodeIfPresent(Int.self, forKey: .tonePitch) ?? d.tonePitch
        intensity = try c.decodeIfPresent(Int.self, forKey: .intensity) ?? d.intensity
        timbre = try c.decodeIfPresent(Int.self, forKey: .timbre) ?? d.timbre
        effect = try c.decodeIfPresent(String.self, forKey: .effect) ?? d.effect
        languageBoost = try c.decodeIfPresent(String.self, forKey: .languageBoost) ?? d.languageBoost
        quality = try c.decodeIfPresent(Bool.self, forKey: .quality) ?? d.quality
        pronunciations = try c.decodeIfPresent([String].self, forKey: .pronunciations) ?? d.pronunciations
        mainWeight = try c.decodeIfPresent(Int.self, forKey: .mainWeight) ?? d.mainWeight
        mixes = try c.decodeIfPresent([Mix].self, forKey: .mixes) ?? d.mixes
        stability = try c.decodeIfPresent(Double.self, forKey: .stability) ?? d.stability
        similarity = try c.decodeIfPresent(Double.self, forKey: .similarity) ?? d.similarity
        style = try c.decodeIfPresent(Double.self, forKey: .style) ?? d.style
        speakerBoost = try c.decodeIfPresent(Bool.self, forKey: .speakerBoost) ?? d.speakerBoost
    }

    static func decode(_ json: String) -> VoiceStyle {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let style = try? JSONDecoder().decode(VoiceStyle.self, from: data) else { return VoiceStyle() }
        return style
    }

    var encoded: String {
        self == VoiceStyle() ? "" : (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// 音效的名字
    static let effects: [(String, String)] = [
        ("", "无"), ("spacious_echo", "空旷回声"), ("auditorium_echo", "礼堂回声"),
        ("lofi_telephone", "电话音"), ("robotic", "机器人"),
    ]

    /// 语言增强能选的（官网支持的全部语言）
    static let languages: [(String, String)] = [
        ("", "跟着语音语言"), ("auto", "自动判断"), ("Chinese", "中文"), ("Chinese,Yue", "粤语"), ("English", "英语"),
        ("Korean", "韩语"), ("Japanese", "日语"), ("French", "法语"), ("German", "德语"), ("Spanish", "西班牙语"),
        ("Portuguese", "葡萄牙语"), ("Italian", "意大利语"), ("Russian", "俄语"), ("Arabic", "阿拉伯语"),
        ("Turkish", "土耳其语"), ("Dutch", "荷兰语"), ("Ukrainian", "乌克兰语"), ("Vietnamese", "越南语"),
        ("Indonesian", "印尼语"), ("Thai", "泰语"), ("Polish", "波兰语"), ("Romanian", "罗马尼亚语"),
        ("Greek", "希腊语"), ("Czech", "捷克语"), ("Finnish", "芬兰语"), ("Hindi", "印地语"),
        ("Bulgarian", "保加利亚语"), ("Danish", "丹麦语"), ("Hebrew", "希伯来语"), ("Malay", "马来语"),
        ("Persian", "波斯语"), ("Slovak", "斯洛伐克语"), ("Swedish", "瑞典语"), ("Croatian", "克罗地亚语"),
        ("Filipino", "菲律宾语"), ("Hungarian", "匈牙利语"), ("Norwegian", "挪威语"), ("Slovenian", "斯洛文尼亚语"),
        ("Catalan", "加泰罗尼亚语"), ("Nynorsk", "新挪威语"), ("Tamil", "泰米尔语"), ("Afrikaans", "南非荷兰语"),
    ]
}

extension Persona {
    var style: VoiceStyle {
        get { VoiceStyle.decode(voiceStyle) }
        set { voiceStyle = newValue.encoded }
    }
}

/// 语音里的语气标签：念的时候保留（模型会念成笑声、叹气、停顿），显示的文字里去掉
enum VoiceTags {
    /// MiniMax 2.8 支持的语气词
    static let minimax = ["laughs", "chuckle", "coughs", "clear-throat", "groans", "breath", "pant", "inhale", "exhale",
                          "gasps", "sniffs", "sighs", "snorts", "burps", "lip-smacking", "humming", "hissing", "emm", "sneezes"]

    private static let minimaxTag = try! Regex("\\((" + minimax.joined(separator: "|") + ")\\)")
    /// ElevenLabs 的写法是方括号：[laughs]、[whispers]
    private static let bracketTag = try! Regex("\\[[A-Za-z][A-Za-z \\-]{1,30}\\]")
    /// MiniMax 的停顿：<#0.5#>
    private static let pause = try! Regex("<#\\d+(\\.\\d+)?#>")
    private static let spaces = try! Regex("[ \\t]{2,}")

    static func strip(_ text: String) -> String {
        var s = text.replacing(minimaxTag, with: "")
        s = s.replacing(bracketTag, with: "")
        s = s.replacing(pause, with: "")
        return s.replacing(spaces, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
