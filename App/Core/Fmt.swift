import Foundation

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Fmt {
    static let zh = Locale(identifier: "zh_CN")
    static let en = Locale(identifier: "en_US")

    private static func make(_ format: String, _ locale: Locale = zh) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = format
        return f
    }

    /// 时间跟着手机的 12/24 小时制和语言走（12 小时制显示上午/下午或 AM/PM）
    static let hm: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
    /// 气泡里的时间：始终带 AM/PM，例如 5:23 PM
    static let bubble = make("h:mm a", en)
    /// 发给模型的时间：24 小时制，不会有歧义
    static let time24 = make("HH:mm")
    /// App 界面现在用的语言（跟着系统里给絮语选的语言）
    static let ui = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "zh-Hans")

    private static func template(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = ui
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    static let md = template("MMMd")
    static let weekday = template("EEE")
    static let weekdayMD = template("MMMdEEE")
    static let enLong = make("EEEE, MMMM d", en)
    static let enMonth = make("MMMM", en)
    static let enMonthDay = make("MMMM d", en)
    static let enMonthShort = make("MMM", en)
    static let ymd = make("yyyy.M.d")
    static let full = make("yyyy年M月d日 EEEE HH:mm")
    static let day = make("yyyy年M月d日 EEEE")

    /// 一段时间说成口语：「40 分钟」「2 个小时」「3 天」
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(1, minutes)) 分钟" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 个小时" }
        return "\(hours / 24) 天"
    }
}

extension Date {
    var listStamp: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return Fmt.hm.string(from: self) }
        if cal.isDateInYesterday(self) { return String(localized: "昨天") }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: self), to: cal.startOfDay(for: .now)).day, days < 7 {
            return Fmt.weekday.string(from: self)
        }
        return Fmt.md.string(from: self)
    }

    var separatorStamp: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return String(localized: "今天") + " " + Fmt.hm.string(from: self) }
        if cal.isDateInYesterday(self) { return String(localized: "昨天") + " " + Fmt.hm.string(from: self) }
        return Fmt.md.string(from: self) + " " + Fmt.hm.string(from: self)
    }

    var startOfDay: Date { Calendar.current.startOfDay(for: self) }

    func adding(days: Int) -> Date { Calendar.current.date(byAdding: .day, value: days, to: self) ?? self }
}
