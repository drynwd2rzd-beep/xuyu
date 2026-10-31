import Foundation

/// 从外面（电脑中继）收到的文件名：只留下单纯的名字，不能带路径。
/// 名字里带 ../ 或斜杠的话，写文件时会跑到别的地方，覆盖 App 自己的数据（审查 Z-039、规范 RELAY-6）
enum FileName {
    /// 去掉路径、控制字符、开头的点和 / \ :，空了就叫「文件」
    static func safe(_ name: String) -> String {
        let base = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let banned = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var cleaned = String(String.UnicodeScalarView(base.unicodeScalars.filter { !banned.contains($0) }))
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? String(localized: "文件") : String(cleaned.prefix(120))
    }
}
