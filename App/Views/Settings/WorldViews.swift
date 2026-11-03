import SwiftUI
import SwiftData

/// 设置 → 世界：大家共用的那一份——生活的世界、天气、关系、几个开关、这周世界里发生的事。
/// 「你是谁」在设置首页的「我」里，每个人自己的生活在编辑角色的「生活」一章里。
/// 这里写的只影响 TA 们怎么说话、什么时候回，聊天页上不显示
struct WorldView: View {
    @Environment(Router.self) private var router
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @State private var s = World.state
    @State private var editing: World.Relation?

    var body: some View {
        SettingsPage(title: "世界") {
            if let line = Weather.shortLine {
                Text(Fmt.enLong.string(from: .now) + " · " + line)
                    .font(Typo.serif(15).italic())
                    .foregroundStyle(Palette.inkSoft)
                    .padding(.horizontal, 6)
            }

            SettingsGroup(title: "The world") {
                TextField("大家生活在什么样的世界：年代、城市、大家在做什么…", text: $s.world, axis: .vertical)
                    .font(Typo.serif(15.5))
                    .lineSpacing(5)
                    .lineLimit(3...12)
                    .padding(Space.card)
            }

            // 真实天气：TA 们按你那边的天气过日子
            SettingsGroup(title: "Weather") {
                WeatherRows()
            }

            relationsGroup
            livingGroup

            Button { router.open(.worldEvents) } label: { weekCard }
                .buttonStyle(ScaleButtonStyle())
        }
        .onChange(of: s) { _, new in World.state = new }
        .onReceive(NotificationCenter.default.publisher(for: World.changed)) { _ in
            // 别处（每天的安排、角色的生活、设置首页的「你是谁」）改了：跟着刷新，但不打断正在打的字
            let latest = World.state
            if latest.lives != s.lives || latest.events != s.events || latest.you != s.you { s = latest }
        }
        .sheet(item: $editing) { r in
            RelationEditor(relation: r, personas: personas.filter { !$0.canWork }) { result in
                var list = s.relations.filter { $0.id != r.id }
                if let result { list.append(result) }
                s.relations = list
            }
            .presentationDetents([.medium])
            .presentationCornerRadius(Radius.sheet)
            .presentationBackground(Palette.paper)
        }
    }

    // MARK: 分组

    /// Relationships：谁和谁是什么关系，点一条改，最后一行添加
    private var relationsGroup: some View {
        SettingsGroup(title: "Relationships") {
            ForEach(s.relations) { r in
                Button { editing = r } label: {
                    SettingRow(title: pairName(r), subtitle: r.text) { Chevron() }
                }
                .buttonStyle(PressableRowStyle())
            }
            Button {
                editing = World.Relation(a: nil, b: personas.first?.id, text: "")
            } label: {
                SettingRow(title: "添加关系") {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                }
            }
            .buttonStyle(PressableRowStyle())
        }
    }

    /// Living：TA 们自己的生活、心情延续、世界在发生三个开关
    private var livingGroup: some View {
        SettingsGroup(title: "Living") {
            SettingRow(title: "TA 们自己的生活", subtitle: "按自己的作息起床、上班、睡觉，每天有自己的事") {
                InkToggle(isOn: $s.lifeOn, label: "TA 们自己的生活")
            }
            SettingRow(title: "心情会延续", subtitle: "今天的情绪会带到聊天里") {
                InkToggle(isOn: $s.moodCarry, label: "心情会延续")
            }
            SettingRow(title: "世界在发生", subtitle: "TA 们之间发生的事大家都知道，会聊起") {
                InkToggle(isOn: $s.eventsOn, label: "世界在发生")
            }
        }
    }

    // MARK: 小件

    private func pairName(_ r: World.Relation) -> String {
        "\(name(r.a)) · \(name(r.b))"
    }

    private func name(_ id: UUID?) -> String {
        guard let id else { return String(localized: "你") }
        return personas.first { $0.id == id }?.name ?? String(localized: "已删除的角色")
    }

    /// 这周世界里发生的事：深色卡片，点进去看全部和快到的日子
    private var weekCard: some View {
        let recent = s.events.filter { Date.now.timeIntervalSince($0.day) < 7 * 86400 }.suffix(3).map(\.text)
        return HStack(spacing: Space.item) {
            VStack(alignment: .leading, spacing: 6) {
                Text("this week in the world").font(Typo.serif(14).italic()).foregroundStyle(Palette.onNoir.opacity(0.6))
                Text(recent.isEmpty ? String(localized: "这周还没什么事。连上电脑后，每天会给大家安排好今天。") : recent.joined(separator: "；"))
                    .font(Typo.serif(15.5))
                    .lineSpacing(5)
                    .foregroundStyle(Palette.onNoir)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.onNoir.opacity(0.6))
        }
        .padding(.horizontal, Space.card + 4)
        .padding(.vertical, 18)
        .background(Palette.noir, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// 添加 / 修改一段关系：哪两个人、是什么关系
struct RelationEditor: View {
    let relation: World.Relation
    let personas: [Persona]
    /// nil = 删掉
    let onDone: (World.Relation?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var a: UUID?
    @State private var b: UUID?
    @State private var text = ""

    init(relation: World.Relation, personas: [Persona], onDone: @escaping (World.Relation?) -> Void) {
        self.relation = relation
        self.personas = personas
        self.onDone = onDone
        _a = State(initialValue: relation.a)
        _b = State(initialValue: relation.b)
        _text = State(initialValue: relation.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            HStack {
                Button("删除", role: .destructive) {
                    onDone(nil)
                    dismiss()
                }
                .foregroundStyle(Palette.danger)
                Spacer()
                Button("完成") {
                    var r = relation
                    r.a = a
                    r.b = b
                    r.text = text.trimmed
                    onDone(r.text.isEmpty || r.a == r.b ? nil : r)
                    dismiss()
                }
                .fontWeight(.semibold)
                .foregroundStyle(Palette.ink)
            }
            .font(.system(size: 16))

            VStack(spacing: 0) {
                SettingRow(title: "一个人") { picker($a) }
                SettingRow(title: "另一个人") { picker($b) }
            }
            .card()

            TextField("是什么关系：大学同学、邻居、在一起 100 天…", text: $text, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(2...5)
                .padding(Space.card)
                .card()
        }
        .padding(Space.page)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func picker(_ value: Binding<UUID?>) -> some View {
        Menu {
            Button("你") { value.wrappedValue = nil }
            ForEach(personas) { p in Button(p.name) { value.wrappedValue = p.id } }
        } label: {
            MenuValue(text: value.wrappedValue.flatMap { id in personas.first { $0.id == id }?.name } ?? String(localized: "你"))
        }
    }
}

/// 世界大事：快到的日子（纪念日、节日）和最近世界里发生的事（长按可以删）
struct WorldEventsView: View {
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @State private var events = World.state.events

    var body: some View {
        SettingsPage(title: "Events") {
            let coming = World.comingUp(personas: personas)
            if !coming.isEmpty {
                SettingsGroup(title: "Coming up") {
                    ForEach(Array(coming.enumerated()), id: \.offset) { index, c in
                        HStack(spacing: Space.item) {
                            VStack(spacing: 0) {
                                Text("\(Calendar.current.component(.day, from: c.day))").font(Typo.display(22))
                                Text(Fmt.enMonthShort.string(from: c.day)).font(Typo.serif(11.5).italic()).foregroundStyle(Palette.inkSoft)
                            }
                            .frame(width: 46)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.what).font(.system(size: 15)).foregroundStyle(Palette.ink)
                                Text(c.sub).font(.system(size: Typo.secondary)).foregroundStyle(Palette.inkSoft)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, Space.card)
                        .frame(minHeight: 58)
                    }
                }
            }
            SettingsGroup(title: "In the world") {
                if events.isEmpty {
                    Text("还没有。连上电脑后，每天会写下世界里发生的一两件小事。")
                        .font(.system(size: 14)).foregroundStyle(Palette.inkSoft).padding(Space.card)
                }
                ForEach(Array(events.reversed().enumerated()), id: \.element.id) { index, e in
                    HStack(alignment: .top, spacing: Space.item) {
                        Text(Fmt.md.string(from: e.day)).font(Typo.serif(13).italic()).foregroundStyle(Palette.inkSoft).frame(width: 46, alignment: .leading)
                        Text(e.text).font(.system(size: 14.5)).lineSpacing(3).foregroundStyle(Palette.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.card)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button(role: .destructive) { remove(e) } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
        }
    }

    private func remove(_ e: World.Event) {
        withAnimation(Motion.spring) { events.removeAll { $0.id == e.id } }
        var s = World.state
        s.events.removeAll { $0.id == e.id }
        World.state = s
    }
}
