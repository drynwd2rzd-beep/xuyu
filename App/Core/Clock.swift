import Foundation

/// 一天里的钟点：作息、免打扰、深夜、几点写日记都用这一套算法（审查 Z-326）。
/// 只管「几点」，不管「TA 能不能开口」（那个按作息和状态判断，在 World / HumanTouch）
enum Clock {
    /// 现在是几点（小时，带小数：8:30 是 8.5）
    static func hour(_ date: Date = .now) -> Double {
        let cal = Calendar.current
        return Double(cal.component(.hour, from: date)) + Double(cal.component(.minute, from: date)) / 60
    }

    /// 某个时刻落在不在「从 a 到 b」里（可以跨过半夜，比如 1 点睡到 8 点半、23 点睡到 7 点）；a 等于 b 时不算在里面
    static func within(_ t: Double, from a: Double, to b: Double) -> Bool {
        a <= b ? (t >= a && t < b) : (t >= a || t < b)
    }
}
