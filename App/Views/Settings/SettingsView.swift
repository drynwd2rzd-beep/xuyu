import SwiftUI
import SwiftData
import PhotosUI

struct SettingsView: View {
    @Environment(RelayClient.self) private var relay
    @Environment(Router.self) private var router
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @AppStorage(Prefs.nickname) private var nickname = ""
    @AppStorage(Prefs.defaultClaudeModel) private var claudeModel = ""
    @AppStorage(Prefs.defaultCodexModel) private var codexModel = ""
    @AppStorage(Prefs.defaultClaudeEffort) private var claudeEffort = ""
    @AppStorage(Prefs.defaultCodexEffort) private var codexEffort = ""
    @AppStorage(MyAvatarStore.stampKey) private var avatarStamp = 0.0
    @State private var avatarItem: PhotosPickerItem?
    @State private var modelEngine: Engine?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                section("连接") {
                    Button { router.open(.connection) } label: {
                        connectionRow(title: "电脑中继", subtitle: relayLine, ok: relay.isConnected, symbol: "desktopcomputer")
                    }
                    .buttonStyle(PressableRowStyle())
                    Hairline(inset: 62)
                    engineRow(.claude)
                    Hairline(inset: 62)
                    engineRow(.codex)
                }

                section("对话") {
                    Button { router.open(.personas) } label: {
                        SettingRow(title: "角色") {
                            Text("\(personas.count) 位").font(.system(size: 14)).foregroundStyle(Palette.inkSoft)
                            Chevron()
                        }
                    }
                    .buttonStyle(PressableRowStyle())
                    Hairline()
                    meRow
                }

                // 不常改的放进二级页面，主页面保持简短
                section("更多") {
                    navRow("通知", route: .notifications)
                    Hairline()
                    navRow("外观与背景", route: .appearance)
                    Hairline()
                    navRow("备份与恢复", route: .backup)
                    Hairline()
                    navRow("语音", route: .voice)
                    Hairline()
                    navRow("隐私与安全", route: .privacy)
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { SubpageHeader(title: "设置") }
        .background(Palette.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $modelEngine) { engine in
            ModelPicker(engine: engine,
                        selection: engine == .claude ? $claudeModel : $codexModel,
                        effort: engine == .claude ? $claudeEffort : $codexEffort,
                        status: relay.status)
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    withAnimation(Motion.spring) { MyAvatarStore.save(data) }
                }
                avatarItem = nil
            }
        }
        .onAppear { relay.refreshStatus() }
    }

    @Environment(\.modelContext) private var context

    /// 二级页面入口：只有名字和箭头，右边不放多余的信息
    private func navRow(_ title: String, route: Route) -> some View {
        Button { router.open(route) } label: {
            SettingRow(title: title) { Chevron() }
        }
        .buttonStyle(PressableRowStyle())
    }

    /// 自己：头像（点一下从相册换，长按可恢复成文字头像）+ 称呼
    private var meRow: some View {
        HStack(spacing: Space.item) {
            PhotosPicker(selection: $avatarItem, matching: .images) {
                UserAvatar(size: 40)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Palette.inkInverse)
                            .frame(width: 17, height: 17)
                            .background(Palette.ink, in: Circle())
                            .overlay(Circle().strokeBorder(Palette.card, lineWidth: 1.5))
                            .offset(x: 3, y: 3)
                    }
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel("更换我的头像")
            .contextMenu {
                if MyAvatarStore.image != nil {
                    Button(role: .destructive) { withAnimation(Motion.spring) { MyAvatarStore.clear() } } label: {
                        Label("移除头像", systemImage: "trash")
                    }
                }
            }
            .id(avatarStamp)
            Text("我").font(.system(size: 16)).foregroundStyle(Palette.ink)
            Spacer()
            TextField("怎么称呼你", text: $nickname)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 15))
                .foregroundStyle(Palette.ink2)
                .frame(maxWidth: 160)
        }
        .padding(.horizontal, Space.card)
        .frame(height: Space.rowTall)
    }

    private var relayLine: String {
        switch relay.state {
        case .connected: relay.status.map { "已连接 · \($0.host)" } ?? "已连接"
        case .connecting: "连接中…"
        case .notConfigured: "未设置"
        case .failed(let reason): reason
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            SectionLabel(text: title)
            VStack(spacing: 0) { content() }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .card()
        }
    }

    private func connectionRow(title: String, subtitle: String, ok: Bool, symbol: String) -> some View {
        HStack(spacing: Space.item) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Palette.ink)
                .frame(width: 34, height: 34)
                .background(Palette.fill, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16)).foregroundStyle(Palette.ink)
                Text(subtitle).font(.system(size: Typo.secondary)).foregroundStyle(Palette.inkSoft).lineLimit(1)
            }
            Spacer()
            StatusDot(ok: ok)
            Chevron()
        }
        .padding(.horizontal, Space.card)
        .frame(height: Space.rowTall)
        .contentShape(Rectangle())
    }

    /// Claude / Codex 一行：显示它的默认模型，点进去选模型和推理强度
    private func engineRow(_ engine: Engine) -> some View {
        let s = engine == .claude ? relay.status?.claude : relay.status?.codex
        let model = engine == .claude ? claudeModel : codexModel
        let effort = engine == .claude ? claudeEffort : codexEffort
        let subtitle: String = if s?.installed == false {
            "电脑上还没有安装"
        } else {
            "默认模型 · " + ModelNames.summary(model, effort, engine: engine, status: relay.status)
        }
        return Button { modelEngine = engine } label: {
            HStack(spacing: Space.item) {
                EngineLogo(engine: engine, size: 18)
                    .frame(width: 34, height: 34)
                    .background(Palette.fill, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.label).font(.system(size: 16)).foregroundStyle(Palette.ink)
                    Text(subtitle).font(.system(size: Typo.secondary)).foregroundStyle(Palette.inkSoft).lineLimit(1)
                }
                Spacer()
                StatusDot(ok: s?.installed == true && relay.isConnected)
                Chevron()
            }
            .padding(.horizontal, Space.card)
            .frame(height: Space.rowTall)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
    }

    static func short(_ model: String) -> String {
        let map = ["claude-opus-5-5": "Opus 5.5", "claude-sonnet-5-5": "Sonnet 5.5", "claude-haiku-5-5": "Haiku 5.5",
                   "claude-fable-5-1": "Fable 5.1", "opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku"]
        return map[model] ?? model
    }
}

struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle()
            .fill(ok ? Color(hex: 0x5E8F58) : Palette.faint)
            .frame(width: 8, height: 8)
            .accessibilityLabel(ok ? "正常" : "未连接")
    }
}

enum ModelNames {
    static func name(_ id: String, engine: Engine, status: RelayStatus?) -> String {
        if id.isEmpty { return "自动" }
        return status?.catalog(for: engine).first { $0.id == id }?.name ?? SettingsView.short(id)
    }

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

struct QuietHoursSheet: View {
    @Binding var start: Int
    @Binding var end: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            HStack {
                Text("免打扰").font(Typo.serif(20, .medium)).foregroundStyle(Palette.ink)
                Spacer()
                Button("完成") { dismiss() }.fontWeight(.semibold).foregroundStyle(Palette.ink)
            }
            HStack {
                picker("开始", $start)
                Text("–").foregroundStyle(Palette.inkSoft)
                picker("结束", $end)
            }
            .padding(Space.card)
            .card()
            Text("这段时间里，角色不会主动给你发消息。").font(.system(size: 13)).foregroundStyle(Palette.inkSoft).padding(.leading, 6)
        }
        .padding(Space.page)
    }

    private func picker(_ label: String, _ value: Binding<Int>) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
            Picker(label, selection: value) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(height: 110)
        }
        .frame(maxWidth: .infinity)
    }
}
