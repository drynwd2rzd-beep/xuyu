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
    static let userBubble = Color.dynamic(light: 0xE2E1DB, dark: 0x2B2B2F)
    static let botBubble = Color.dynamic(light: 0xFFFFFF, dark: 0x1D1D20)
    static let noir = Color.dynamic(light: 0x0E0E10, dark: 0xF2F2F4)
    static let onNoir = Color.dynamic(light: 0xFFFFFF, dark: 0x0E0E10)
    static let danger = Color.dynamic(light: 0xD4485F, dark: 0xEC6B80)
    static let highlight = Color.dynamic(light: 0xEADFC4, dark: 0x4A4232)
    static let clay = Color(hex: 0xD97757)
    /// 浮在灰底上的一块：分段控件选中的那一格
    static let raised = Color.dynamic(light: 0xFFFFFF, dark: 0x3A3A3D)
    /// 「已连接」「装好了」的小绿点
    static let online = Color(hex: 0x34C27A)
    /// 照片统一调色里那层暖光（PhotoGrade）
    static let photoWarmth = Color(hex: 0xFFB070)

    static let avatarTints: [UInt32] = [0x1E1E1F, 0xE7E3DA, 0xD8C5AE, 0xB7C3B1, 0xAEBFCE, 0xD6B9B6]
}

enum Typo {
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    // 反复出现的几种字：同一种用途只用这一个字号，页面里不再各写各的数字。
    // 新版设计只用 11 · 13 · 15 · 17 · 22 五档
    /// 正文：气泡和动态里的字、输入框、设置行
    static let body: CGFloat = 15
    /// 分区标题、页内小标签、分段控件
    static let label: CGFloat = 13
    /// 副标题、次要说明（行下面那一行灰字、点赞、回复对象）
    static let secondary: CGFloat = 13
    /// 更小的注释：图片张数、工作过程、代码块语言、设置里的分区小标签
    static let caption: CGFloat = 11
    /// 名字、子页面标题
    static let title: CGFloat = 17
    /// 页面大标题（细字、宽字距）
    static let heading: CGFloat = 22
    /// 设置行的标题（UI-1）
    static let rowTitle: CGFloat = 15
    /// 设置行右边的当前值
    static let value: CGFloat = 13

    /// 中文小标题、设置行的字距：新版设计的字都略微拉开
    static let tracking: CGFloat = 0.6
    /// 英文小标签（AI、App、分区名）的大字距
    static let labelTracking: CGFloat = 3
}

/// 统一圆角：所有页面只从这里取值，全部使用 iPhone 屏幕同款的连续曲率圆角（.continuous）。
enum Radius {
    /// iPhone 屏幕本身的圆角：整页在动时（侧滑返回）四角跟屏幕一样圆
    static let screen: CGFloat = 55
    /// 卡片、文字块
    static let card: CGFloat = 18
    /// 照片卡（画册、瀑布流）
    static let photo: CGFloat = 8
    /// 小方块：表情、组件库图标、代码块
    static let tile: CGFloat = 18
    /// 聊天气泡
    static let bubble: CGFloat = 20
    /// 底部弹出面板顶部
    static let sheet: CGFloat = 38
    /// 小控件：头像底色块、分段内块
    static let control: CGFloat = 12
}

extension Shape where Self == RoundedRectangle {
    /// 统一的连续曲率圆角矩形
    static func rounded(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// 统一间距
enum Space {
    /// 页面左右边距
    static let page: CGFloat = 18
    /// 卡片与卡片之间
    static let section: CGFloat = 14
    /// 设置里一组和一组之间：靠留白分开，不加线
    static let group: CGFloat = 24
    /// 滚动页最下面留的空
    static let bottom: CGFloat = 40
    /// 卡片内边距
    static let card: CGFloat = 16
    /// 元素之间
    static let item: CGFloat = 12
    /// 紧凑处
    static let tight: CGFloat = 8
    /// 列表行高
    static let row: CGFloat = 52
    /// 带副标题的行高
    static let rowTall: CGFloat = 60
    /// 输入框、按钮高度
    static let control: CGFloat = 42
    /// 页面顶部到标题
    static let top: CGFloat = 16
}

/// 统一的弹簧动画
enum Motion {
    /// 主动画：稍慢、几乎不回弹，温柔地落位
    static let spring = Animation.spring(duration: 0.52, bounce: 0.06)
    /// 小切换（分段、筛选、按钮图标）：短一点，同样不弹
    static let snappy = Animation.spring(duration: 0.36, bounce: 0)
    /// 滚动、背景这类大面积变化：平滑淡入淡出
    static let glide = Animation.smooth(duration: 0.48)
    /// 按下：很快地沉下去
    static let pressIn = Animation.spring(duration: 0.2, bounce: 0)
    /// 松手：慢慢地回来，不弹跳
    static let pressOut = Animation.spring(duration: 0.5, bounce: 0)
    /// 拖动松手后的归位：跟着手势速度，柔和收尾
    static let settle = Animation.interpolatingSpring(mass: 1, stiffness: 170, damping: 24)
    /// 很快地淡掉（或在原地换一样东西）：小点变字前淡出、切页前旧页淡出、键盘和面板互换
    static let fade = Animation.easeOut(duration: 0.18)
    /// 打开聊天：从点的那一行飞进去，一气呵成不回弹
    static var shuttleIn: Animation { reduced ? .easeInOut(duration: 0.3) : .spring(duration: 0.5, bounce: 0) }
    /// 返回：聊天页像雾一样散开，列表退回原位
    static var shuttleOut: Animation { reduced ? .easeInOut(duration: 0.3) : .timingCurve(0.25, 0.6, 0.3, 1, duration: 0.46) }
    /// 系统设置里打开了「减少动态效果」：放大、飞入、滑动都换成原地淡入淡出
    static var reduced: Bool { UIAccessibility.isReduceMotionEnabled }
    // 气泡（以 iMessage 为准）：所有气泡——你发的、TA 回的、正在输入的小点、表情、图片、语音、文件——都只用下面这两条，
    // 节奏完全一样。气泡本身轻轻一弹；被它带动的滚动（上面的消息让开）平稳不弹，不然整列消息会跟着晃

    /// 气泡带动的变化：新的一行进来时滚到最新、撤回、拿掉
    static let bubble = Animation.spring(duration: 0.42, bounce: 0)
    /// 气泡本身放大显现的那一下（新消息、小点变成文字）：同样的时长，带一点弹性
    static let bubblePop = Animation.spring(duration: 0.42, bounce: 0.2)

    // 等动画走完再做下一步（ARCH-5）：能用 onDismiss 回调的地方用回调，用不了的（推出去的页面退回、聊天层散开）才等这两个

    /// 页面退回、sheet 收起、聊天层散开要的时间：走完再删数据、再弹下一个（删了还在显示的东西会闪一下或变成空白页）
    static let dismissSettle = Duration.milliseconds(450)
    /// 长按菜单收起要的时间：收起后再展开别的，两个动画不撞在一起
    static let menuSettle = Duration.milliseconds(380)
}

