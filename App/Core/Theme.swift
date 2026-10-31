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

/// 统一设计规范：纸白底、白卡片、墨黑强调，所有颜色同时有深色版本。
enum Palette {
    static let paper = Color.dynamic(light: 0xF3F2EE, dark: 0x0C0C0D)
    static let card = Color.dynamic(light: 0xFFFFFF, dark: 0x19191B)
    static let fill = Color.dynamic(light: 0xEDECE7, dark: 0x252528)
    static let ink = Color.dynamic(light: 0x1B1B1C, dark: 0xF1F0EC)
    static let inkInverse = Color.dynamic(light: 0xF6F5F1, dark: 0x111112)
    static let inkSoft = Color.dynamic(light: 0x6C6C70, dark: 0x9E9EA3)
    static let ink2 = Color.dynamic(light: 0x3A3A3C, dark: 0xC9C8C4)
    static let faint = Color.dynamic(light: 0xA8A7A2, dark: 0x5C5C61)
    static let hairline = Color.dynamic(light: 0xE4E2DC, dark: 0x2A2A2E)
    static let userBubble = Color.dynamic(light: 0xE2E1DB, dark: 0x2B2B2F)
    static let botBubble = Color.dynamic(light: 0xFFFFFF, dark: 0x1D1D20)
    static let noir = Color.dynamic(light: 0x1D1D1E, dark: 0xF1F0EC)
    static let onNoir = Color.dynamic(light: 0xF4F3EF, dark: 0x141415)
    static let danger = Color.dynamic(light: 0xB8463A, dark: 0xE0705F)
    static let highlight = Color.dynamic(light: 0xEADFC4, dark: 0x4A4232)
    static let clay = Color(hex: 0xD97757)

    static let avatarTints: [UInt32] = [0x1E1E1F, 0xE7E3DA, 0xD8C5AE, 0xB7C3B1, 0xAEBFCE, 0xD6B9B6]
}

enum Typo {
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    // 反复出现的几种字：同一种用途只用这一个字号，页面里不再各写各的数字
    /// 正文：气泡和动态里的字、输入框
    static let body: CGFloat = 15.5
    /// 分区标题、页内小标签、分段控件
    static let label: CGFloat = 13.5
    /// 副标题、次要说明（行下面那一行灰字、点赞、回复对象）
    static let secondary: CGFloat = 12.5
    /// 更小的注释：图片张数、工作过程、代码块语言
    static let caption: CGFloat = 11.5
}

/// 统一圆角：所有页面只从这里取值，全部使用 iPhone 屏幕同款的连续曲率圆角（.continuous）。
enum Radius {
    /// iPhone 屏幕本身的圆角：整页在动时（侧滑返回）四角跟屏幕一样圆
    static let screen: CGFloat = 55
    /// 卡片、列表容器
    static let card: CGFloat = 26
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

/// 页头背景：页头本身是纸色，下方再延伸一段柔和淡出，内容滚上来不会和标题叠在一起
struct HeaderFade: View {
    var fade: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            Palette.paper
            LinearGradient(colors: [Palette.paper, Palette.paper.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: fade)
        }
        .padding(.bottom, -fade)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}

/// 屏幕上下边缘的纸色渐变：由浓到淡，中间几段放缓，看起来是自然地隐去而不是一条分界线
struct EdgeFade: View {
    let edge: VerticalEdge

    var body: some View {
        LinearGradient(stops: [
            .init(color: Palette.paper.opacity(0.97), location: 0),
            .init(color: Palette.paper.opacity(0.86), location: 0.3),
            .init(color: Palette.paper.opacity(0.55), location: 0.6),
            .init(color: Palette.paper.opacity(0.2), location: 0.85),
            .init(color: Palette.paper.opacity(0), location: 1),
        ], startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
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
    /// 松手：慢慢地回弹
    static let pressOut = Animation.spring(duration: 0.5, bounce: 0.18)
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

struct CardStyle: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            // 阴影只投在卡片底板上：加在整块卡片上的话，里面每一行（各有白底）都会各投一圈阴影，看起来像一块块单独的小卡片
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.card)
                    .shadow(color: .black.opacity(0.035), radius: 14, y: 5)
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.hairline.opacity(0.8), lineWidth: 0.5))
    }
}

extension View {
    func card(radius: CGFloat = Radius.card) -> some View { modifier(CardStyle(radius: radius)) }
}

/// 只要卡片的阴影（照片类小组件自己有内容铺满，阴影放在它们后面）
struct CardShadow: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(Palette.card)
            .shadow(color: .black.opacity(0.05), radius: 14, y: 5)
    }
}

/// 列表行：按下时底色淡淡浮现，松手后慢慢退去
struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Palette.fill.opacity(configuration.isPressed ? 1 : 0))
            .animation(configuration.isPressed ? .easeOut(duration: 0.1) : .easeOut(duration: 0.42), value: configuration.isPressed)
    }
}

/// 按钮、卡片：按下轻轻缩一点，松手柔和弹回
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(configuration.isPressed ? Motion.pressIn : Motion.pressOut, value: configuration.isPressed)
    }
}

/// 新出现的消息（像 iMessage）：这一行一进来就是它本来的高度，气泡从它那一边的下角放大、显现，轻轻一弹；
/// 你发的那条还会从下面（输入框那里）升上来一点。上面的消息让开，交给聊天页带动画滚到最新（同一条 Motion.bubble）。
/// 以前这一行的高度是一帧一帧长出来的，和滚动各算各的「底」，真机录屏里整列消息会先往下掉一截再往上窜。旧内容直接显示，不重播
struct RiseIn: ViewModifier {
    let fresh: Bool
    var anchor: UnitPoint = .bottom
    /// 从下面升上来多少（你发的消息：从输入框那里升上来）
    var rise: CGFloat = 0
    @State private var popped = false

    func body(content: Content) -> some View {
        let pop = !fresh || popped
        // 减少动态效果：不放大、不升，只在原地淡入
        let still = Motion.reduced
        content
            .scaleEffect(pop || still ? 1 : 0.8, anchor: anchor)
            .offset(y: pop || still ? 0 : rise)
            .opacity(pop ? 1 : 0)
            .onAppear {
                guard fresh, !popped else { return }
                withAnimation(Motion.bubblePop) { popped = true }
            }
    }
}

extension View {
    /// 出现只由 RiseIn 自己来演，不再叠一层列表默认的淡入（两层淡入节奏不同，看起来像闪了一下）；
    /// 拿掉时（多出来的「正在输入」、删除）像 iMessage 一样朝自己那一边的下角缩回去、淡掉
    func riseIn(fresh: Bool, anchor: UnitPoint = .bottom, rise: CGFloat = 0) -> some View {
        modifier(RiseIn(fresh: fresh, anchor: anchor, rise: rise))
            .transition(.asymmetric(insertion: .identity,
                                    removal: Motion.reduced ? .opacity : .opacity.combined(with: .scale(scale: 0.8, anchor: anchor))))
    }
}

/// 根页面的大标题
struct PageTitle<Trailing: View>: View {
    var caption: String? = nil
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if let caption {
                    Text(caption).font(Typo.serif(15)).foregroundStyle(Palette.inkSoft)
                }
                Text(title)
                    .font(Typo.display(40))
                    .tracking(-0.6)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 2)
    }
}

struct CircleIconButton: View {
    let systemName: String
    var label: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 40, height: 40)
                .background(Palette.card, in: Circle())
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 0.5))
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel(label)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(LocalizedStringKey(text))
            .font(Typo.serif(Typo.label))
            .foregroundStyle(Palette.inkSoft)
            .padding(.leading, 6)
    }
}

/// 设置行右边「当前值 ⌃⌄」：点开是一个菜单（模型、推理强度、追问时间等都用它，样子统一）
struct MenuValue: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Text(LocalizedStringKey(text)).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
        }
        .font(.system(size: 15))
        .foregroundStyle(Palette.ink2)
    }
}

/// 灰底白块的分段控件
struct Segmented<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let on = item.0 == selection
                Button {
                    withAnimation(Motion.snappy) { selection = item.0 }
                } label: {
                    Text(LocalizedStringKey(item.1))
                        .font(.system(size: Typo.label, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Palette.ink : Palette.inkSoft)
                        .padding(.horizontal, 13)
                        .frame(height: 30)
                        .frame(maxWidth: .infinity)
                        .background {
                            if on {
                                Capsule().fill(Palette.card)
                                    .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Palette.fill, in: Capsule())
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// 墨黑开关
struct InkToggle: View {
    @Binding var isOn: Bool
    var label: String

    var body: some View {
        Toggle(LocalizedStringKey(label), isOn: $isOn)
            .labelsHidden()
            .tint(Palette.ink)
    }
}

/// 设置类卡片里的一行
struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.system(size: 16)).foregroundStyle(Palette.ink)
                if let subtitle {
                    Text(LocalizedStringKey(subtitle)).font(.system(size: Typo.secondary)).foregroundStyle(Palette.inkSoft)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Space.card)
        // 说明文字折成两行时上下也留出呼吸的空间
        .padding(.vertical, subtitle == nil ? 0 : Space.tight)
        .frame(minHeight: subtitle == nil ? Space.row : Space.rowTall)
        .contentShape(Rectangle())
    }
}

struct Hairline: View {
    var inset: CGFloat = Space.card
    var body: some View {
        Rectangle().fill(Palette.hairline).frame(height: 0.5).padding(.leading, inset)
    }
}

struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.faint)
    }
}

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
