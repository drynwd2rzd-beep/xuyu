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

/// 统一的弹簧动画
enum Motion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let snappy = Animation.snappy(duration: 0.3)
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

struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Palette.fill : Color.clear)
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
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

    static let hm = make("HH:mm")
    static let md = make("M月d日")
    static let mdhm = make("M月d日 HH:mm")
    static let weekday = make("EEE")
    static let weekdayMD = make("EEE · M月d日")
    static let enLong = make("EEEE, MMMM d", en)
    static let enShort = make("EEE, MMM d", en)
    static let enMonth = make("MMMM", en)
    static let ymd = make("yyyy.M.d")
    static let full = make("yyyy年M月d日 EEEE HH:mm")
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
        return Fmt.mdhm.string(from: self)
    }

    var startOfDay: Date { Calendar.current.startOfDay(for: self) }

    func adding(days: Int) -> Date { Calendar.current.date(byAdding: .day, value: days, to: self) ?? self }
}
