import Foundation

/// 由谁驱动：电脑上的 Claude Code 还是 Codex。存的是原始值字符串（`Persona.engineRaw`），名字不能改（DATA-4）。
/// 放在 Core：设置（`Prefs.defaultModel(for:)`）和数据模型都要用它（ARCH-1）
enum Engine: String, Codable, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var label: String { self == .claude ? "Claude" : "Codex" }
}
