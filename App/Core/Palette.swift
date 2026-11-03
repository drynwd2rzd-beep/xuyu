import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

/// 统一设计规范（2026-11 新版，设计素材/设计规范-草案.md）：白底、浅灰块代替卡片和阴影、墨黑字，
/// 质感交给照片（见 PhotoGrade）。所有颜色同时有深色版本。
enum Palette {
    /// 页面底色（名字沿用以前的纸色）
    static let paper = Color.dynamic(light: 0xFFFFFF, dark: 0x0B0B0C)
    /// 卡片、文字块、胶囊：白底上的一块浅灰，不加阴影和描边
    static let card = Color.dynamic(light: 0xF5F5F7, dark: 0x1C1C1E)
    /// 按下的行、分段控件的底槽、开关关着的轨道：比卡片再深一点
    static let fill = Color.dynamic(light: 0xECECEF, dark: 0x2A2A2D)
    static let ink = Color.dynamic(light: 0x0E0E10, dark: 0xF2F2F4)
    static let inkInverse = Color.dynamic(light: 0xFFFFFF, dark: 0x0E0E10)
    /// 次要字
    static let inkSoft = Color.dynamic(light: 0x8B8B92, dark: 0x98989F)
    static let ink2 = Color.dynamic(light: 0x3A3A40, dark: 0xCACACF)
    /// 只用于装饰和不可用状态（UI-9）：箭头、页脚
    static let faint = Color.dynamic(light: 0xC1C1C7, dark: 0x55555B)
    /// 细线：只留给表格、代码块这类内容本身的边（设计规范不用横贯的分割线）
    static let hairline = Color.dynamic(light: 0xECECEF, dark: 0x2A2A2E)
    /// 你的气泡：iMessage 的蓝，上面的字是白的（onUserBubble）
    static let userBubble = Color.dynamic(light: 0x0A7CFF, dark: 0x0A84FF)
    static let onUserBubble = Color(hex: 0xFFFFFF)
    /// TA 的气泡：iMessage 的浅灰，字用 ink
    static let botBubble = Color.dynamic(light: 0xE9E9EB, dark: 0x262628)
    /// 页头、输入栏的磨砂底：半透明的底色，下面的消息隐约透出来（不加分割线，靠这个分层）
    static let frosted = Color.dynamic(light: 0xFFFFFF, dark: 0x0B0B0C).opacity(0.86)
    static let noir = Color.dynamic(light: 0x0E0E10, dark: 0xF2F2F4)
    static let onNoir = Color.dynamic(light: 0xFFFFFF, dark: 0x0E0E10)
    static let danger = Color.dynamic(light: 0xD4485F, dark: 0xEC6B80)
    static let highlight = Color.dynamic(light: 0xEADFC4, dark: 0x4A4232)
    static let clay = Color(hex: 0xD97757)
    /// 浮在灰底上的一块：分段控件选中的那一格
    static let raised = Color.dynamic(light: 0xFFFFFF, dark: 0x3A3A3D)
    /// 「已连接」「装好了」的小绿点
    static let online = Color(hex: 0x34C27A)
    /// 压在照片上的字和小图标（画册封面、动态那一页）：不跟深浅色变
    static let onPhoto = Color(hex: 0xFFFFFF)
    /// 照片上下两头压暗的那层，让白字看得清
    static let photoShade = Color(hex: 0x000000)
    /// 画册里一起听那一页：固定的黑底
    static let listenNight = Color(hex: 0x000000)
    /// 照片统一调色里那层暖光（PhotoGrade）
    static let photoWarmth = Color(hex: 0xFFB070)

    /// 心情光晕的几种颜色（照设计稿）：光团的三层（m1 最浓、m2、m3 最外圈）和那一页的两层底色（t1 上、t2 下）。
    /// 哪种心情用哪一套见 MoodTint；光团在深色下照样亮，底色在深色下换成很暗的同色调
    struct Glow: Equatable {
        let m1: Color, m2: Color, m3: Color
        let t1: Color, t2: Color
    }

    enum Mood {
        /// 开心、兴奋、满足：暖橙
        static let bright = Glow(m1: Color(hex: 0xFF5A1F), m2: Color(hex: 0xFF8A5B), m3: Color(hex: 0xF7A6C4),
                                 t1: .dynamic(light: 0xFDF3EF, dark: 0x1A1210), t2: .dynamic(light: 0xFFF8F4, dark: 0x0B0B0C))
        /// 惬意、温柔、安心：粉
        static let tender = Glow(m1: Color(hex: 0xF2547A), m2: Color(hex: 0xFFB3C6), m3: Color(hex: 0xFFD79A),
                                 t1: .dynamic(light: 0xFDF0F3, dark: 0x1A1013), t2: .dynamic(light: 0xFFF8F6, dark: 0x0B0B0C))
        /// 平静：蓝
        static let calm = Glow(m1: Color(hex: 0x4FB3EE), m2: Color(hex: 0xCDEFFF), m3: Color(hex: 0x92A9F6),
                               t1: .dynamic(light: 0xEEF6FD, dark: 0x0F151A), t2: .dynamic(light: 0xF7FAFF, dark: 0x0B0B0C))
        /// 累了、疲惫、无聊、困：紫
        static let tired = Glow(m1: Color(hex: 0x7466F2), m2: Color(hex: 0xD9D3FF), m3: Color(hex: 0xCFE0FF),
                                t1: .dynamic(light: 0xF3F1FF, dark: 0x13111C), t2: .dynamic(light: 0xF9F8FF, dark: 0x0B0B0C))
        /// 低落、难过、别的：灰蓝
        static let low = Glow(m1: Color(hex: 0x8E9BB5), m2: Color(hex: 0xD5DCEA), m3: Color(hex: 0xB9C3D9),
                              t1: .dynamic(light: 0xF2F4F8, dark: 0x111316), t2: .dynamic(light: 0xFAFBFC, dark: 0x0B0B0C))
    }

    /// 加号菜单圆图标的渐变（深色、浅色），照设计稿；压在图标上的符号是白的，不分深浅色
    enum Menu {
        static let call = (Color(hex: 0x35B871), Color(hex: 0x9BE6B8))
        static let listen = (Color(hex: 0xF2547A), Color(hex: 0xFFB3C6))
        static let read = (Color(hex: 0xE8A33A), Color(hex: 0xFFD79A))
        static let note = (Color(hex: 0x8C7BF0), Color(hex: 0xD3CBFF))
        static let photo = (Color(hex: 0xFF7A45), Color(hex: 0xFFC9A3))
        static let file = (Color(hex: 0x4FB3EE), Color(hex: 0xCDEFFF))
        static let camera = (Color(hex: 0x8E8E95), Color(hex: 0xD5D5DA))
        static let mention = (Color(hex: 0x7466F2), Color(hex: 0xD9D3FF))
    }

    static let avatarTints: [UInt32] = [0x1E1E1F, 0xE7E3DA, 0xD8C5AE, 0xB7C3B1, 0xAEBFCE, 0xD6B9B6]
}

