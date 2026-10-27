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
    static let switchOff = Color.dynamic(light: 0xD9D8D3, dark: 0x3A3A3D)
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
}

/// 统一圆角：所有页面只从这里取值，全部使用 iPhone 屏幕同款的连续曲率圆角（.continuous）。
/// 贴着屏幕边缘的元素与屏幕圆角同心：半径 = 屏幕圆角 − 与屏幕边缘的距离。
enum Radius {
    /// iPhone 屏幕圆角（Face ID 机型约 55pt）
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

    /// 与屏幕同心的圆角
    static func concentric(inset: CGFloat) -> CGFloat { max(screen - inset, control) }
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

/// 滚动内容在页头、底栏附近自己慢慢变淡，露出后面的背景；不盖底色、不用毛玻璃，换什么背景都自然
struct EdgeFade: ViewModifier {
    var top: CGFloat = 56
    var bottom: CGFloat = 18

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    // 页头、底栏所在的位置（safeAreaInset 撑出来的安全区）里内容不显示
                    Color.clear.frame(height: max(0, geo.safeAreaInsets.top - top * 0.35))
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.35), location: 0.45),
                                           .init(color: .black, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: top)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: bottom)
                    Color.clear.frame(height: max(0, geo.safeAreaInsets.bottom - bottom * 0.5))
                }
                .ignoresSafeArea()
            }
        }
    }
}

extension View {
    func edgeFade(top: CGFloat = 56, bottom: CGFloat = 18) -> some View { modifier(EdgeFade(top: top, bottom: bottom)) }
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
}

struct CardStyle: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Palette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.hairline.opacity(0.8), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.035), radius: 14, y: 5)
    }
}

extension View {
    func card(radius: CGFloat = Radius.card) -> some View { modifier(CardStyle(radius: radius)) }
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

/// 新出现的内容（刚发出/刚收到的消息）从下方轻轻浮起；旧内容直接显示，不重播
struct RiseIn: ViewModifier {
    let fresh: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        let on = !fresh || shown
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 14)
            .scaleEffect(on ? 1 : 0.97, anchor: .bottom)
            .onAppear {
                guard fresh, !shown else { return }
                withAnimation(Motion.spring) { shown = true }
            }
    }
}

extension View {
    func riseIn(fresh: Bool) -> some View { modifier(RiseIn(fresh: fresh)) }
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
        Text(text)
            .font(Typo.serif(13.5))
            .foregroundStyle(Palette.inkSoft)
            .padding(.leading, 6)
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
                    Text(item.1)
                        .font(.system(size: 13.5, weight: on ? .semibold : .regular))
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
        Toggle(label, isOn: $isOn)
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
                Text(title).font(.system(size: 16)).foregroundStyle(Palette.ink)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Palette.inkSoft)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Space.card)
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
    static let md = make("M月d日")
    static let weekday = make("EEE")
    static let weekdayMD = make("EEE · M月d日")
    static let enLong = make("EEEE, MMMM d", en)
    static let enShort = make("EEE, MMM d", en)
    static let enMonth = make("MMMM", en)
    static let ymd = make("yyyy.M.d")
    static let full = make("yyyy年M月d日 EEEE HH:mm")
    static let day = make("yyyy年M月d日 EEEE")
}

extension Date {
    var listStamp: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return Fmt.hm.string(from: self) }
        if cal.isDateInYesterday(self) { return "昨天" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: self), to: cal.startOfDay(for: .now)).day, days < 7 {
            return Fmt.weekday.string(from: self)
        }
        return Fmt.md.string(from: self)
    }

    var separatorStamp: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "今天 " + Fmt.hm.string(from: self) }
        if cal.isDateInYesterday(self) { return "昨天 " + Fmt.hm.string(from: self) }
        return Fmt.md.string(from: self) + " " + Fmt.hm.string(from: self)
    }

    var startOfDay: Date { Calendar.current.startOfDay(for: self) }

    func adding(days: Int) -> Date { Calendar.current.date(byAdding: .day, value: days, to: self) ?? self }
}
