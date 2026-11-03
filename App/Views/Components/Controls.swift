import SwiftUI

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
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel(label)
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
        .font(.system(size: Typo.value))
        .tracking(Typo.tracking)
        .foregroundStyle(Palette.inkSoft)
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
                                Capsule().fill(Palette.raised)
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

/// 开关：平时墨黑，编辑某位角色时是 TA 的心情色（toggleTint）
struct InkToggle: View {
    @Binding var isOn: Bool
    var label: String
    @Environment(\.toggleTint) private var tint

    var body: some View {
        Toggle(LocalizedStringKey(label), isOn: $isOn)
            .labelsHidden()
            .tint(tint)
    }
}

/// 设置里的一行：字略微拉开，右边是当前值或开关
struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Space.item) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(.system(size: Typo.rowTitle)).tracking(Typo.tracking).foregroundStyle(Palette.ink)
                if let subtitle {
                    Text(LocalizedStringKey(subtitle)).font(.system(size: Typo.caption)).foregroundStyle(Palette.inkSoft)
                }
            }
            Spacer(minLength: Space.tight)
            trailing
        }
        .padding(.horizontal, Space.card)
        // 说明文字折成两行时上下也留出呼吸的空间
        .padding(.vertical, subtitle == nil ? 0 : Space.tight)
        .frame(minHeight: subtitle == nil ? Space.row : Space.rowTall)
        .contentShape(Rectangle())
    }
}

struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.faint)
    }
}

extension EnvironmentValues {
    /// 开关打开时的颜色：平时是墨黑，编辑某位角色时换成 TA 的心情色（设计稿「开的时候填成 TA 的心情色」）
    @Entry var toggleTint: Color = Palette.ink
}
