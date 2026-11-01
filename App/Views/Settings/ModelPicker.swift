import SwiftUI

// MARK: - 模型名字

/// 模型和推理强度在界面上叫什么：优先用电脑中继报来的模型清单，没有时用简写
enum ModelNames {
    /// 模型 ID 显示成的名字；空 = 自动
    static func name(_ id: String, engine: Engine, status: RelayStatus?) -> String {
        if id.isEmpty { return "自动" }
        return status?.catalog(for: engine).first { $0.id == id }?.name ?? SettingsView.short(id)
    }

    /// 「模型 · 推理强度」一行字（没选推理强度就只有模型）
    static func summary(_ id: String, _ effort: String, engine: Engine, status: RelayStatus?) -> String {
        let n = name(id, engine: engine, status: status)
        return effort.isEmpty ? n : "\(n) · \(EffortName.label(effort))"
    }

    /// 某个模型能选的推理强度；不知道时给通用的一组
    static func efforts(for id: String, engine: Engine, status: RelayStatus?) -> [String] {
        let list = status?.catalog(for: engine) ?? []
        if let m = list.first(where: { $0.id == id }), !m.efforts.isEmpty { return m.efforts }
        if id.isEmpty, let first = list.first, !first.efforts.isEmpty { return first.efforts }
        return ["low", "medium", "high", "xhigh", "max"]
    }
}

// MARK: - 选默认模型

/// 某一个引擎（Claude 或 Codex）的默认模型和推理强度
struct ModelPicker: View {
    let engine: Engine
    @Binding var selection: String
    @Binding var effort: String
    let status: RelayStatus?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                HStack(spacing: Space.tight) {
                    EngineLogo(engine: engine, size: 18)
                    Text("\(engine.label) 默认模型").font(Typo.serif(20, .medium)).foregroundStyle(Palette.ink)
                    Spacer()
                    Button("完成") { dismiss() }.fontWeight(.semibold).foregroundStyle(Palette.ink)
                }
                group(selection: $selection, effort: $effort)
            }
            .padding(Space.page)
        }
    }

    private func group(selection: Binding<String>, effort: Binding<String>) -> some View {
        let models = status?.catalog(for: engine) ?? []
        return VStack(alignment: .leading, spacing: Space.tight) {
            VStack(spacing: 0) {
                row("自动", subtitle: "账号默认的模型", value: "", selection: selection)
                ForEach(models) { m in
                    Hairline()
                    row(m.name, subtitle: m.description.isEmpty ? nil : m.description, value: m.id, selection: selection)
                }
                Hairline()
                SettingRow(title: "推理强度", subtitle: "越高越聪明，也越慢、越耗额度") {
                    EffortMenu(options: ModelNames.efforts(for: selection.wrappedValue, engine: engine, status: status),
                               selection: effort)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .card()
            if models.isEmpty {
                Text("连接电脑后显示可用的模型").font(.system(size: Typo.secondary)).foregroundStyle(Palette.inkSoft).padding(.leading, 6)
            }
        }
    }

    private func row(_ title: String, subtitle: String?, value: String, selection: Binding<String>) -> some View {
        Button { selection.wrappedValue = value } label: {
            SettingRow(title: title, subtitle: subtitle) {
                if selection.wrappedValue == value {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                }
            }
        }
        .buttonStyle(PressableRowStyle())
        .sensoryFeedback(.selection, trigger: selection.wrappedValue)
    }
}

// MARK: - 推理强度

/// 推理强度选择：默认 + 模型支持的几档
struct EffortMenu: View {
    let options: [String]
    @Binding var selection: String

    var body: some View {
        Menu {
            item("", "默认")
            ForEach(options, id: \.self) { e in item(e, EffortName.label(e)) }
        } label: {
            MenuValue(text: EffortName.label(selection))
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    @ViewBuilder
    private func item(_ value: String, _ title: String) -> some View {
        Button { selection = value } label: {
            if selection == value { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}
