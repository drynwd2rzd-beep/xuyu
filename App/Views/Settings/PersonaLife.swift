import SwiftUI

/// 编辑角色「生活」一章：TA 在这个世界里是谁、此刻在做什么、作息、今天的安排
struct PersonaLifeGroups: View {
    let persona: Persona
    @State private var life: World.Life

    init(persona: Persona) {
        self.persona = persona
        _life = State(initialValue: World.life(persona.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            HStack(spacing: Space.item) {
                AvatarView(persona: persona, size: 56)
                TextField("TA 在这个世界里是谁：职业、住在哪…", text: $life.role, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(1...4)
            }
            .padding(Space.card)
            .card()

            nowCard

            SettingsGroup(title: "作息") {
                SettingRow(title: "真实作息") { InkToggle(isOn: $life.realRhythm, label: "真实作息") }
                if life.realRhythm {
                    SettingRow(title: "睡觉") { hourMenu($life.rhythm.sleep) ; Text("–").foregroundStyle(Palette.inkSoft); hourMenu($life.rhythm.wake) }
                    SettingRow(title: "忙") { hourMenu($life.rhythm.busyFrom) ; Text("–").foregroundStyle(Palette.inkSoft); hourMenu($life.rhythm.busyTo) }
                    SettingRow(title: "周末不忙") { InkToggle(isOn: $life.rhythm.weekendFree, label: "周末不忙") }
                }
            }
            .animation(Motion.spring, value: life.realRhythm)

            if !todayPlan.isEmpty {
                SettingsGroup(title: "今天") {
                    ForEach(Array(todayPlan.enumerated()), id: \.offset) { index, item in
                        planRow(item, index: index)
                    }
                }
            }
        }
        .onChange(of: life) { _, new in World.setLife(new, for: persona.id) }
    }

    private var todayPlan: [World.PlanItem] {
        guard let day = life.planDay, Calendar.current.isDateInToday(day) else { return [] }
        return life.plan
    }

    /// 此刻：深色卡片，TA 正在做什么、回得快不快、心情
    private var nowCard: some View {
        let status = World.status(of: persona.id)
        let doing = World.current(of: persona.id)?.what
        let line: String = switch status {
        case .asleep: String(localized: "在睡觉，\(World.clock(life.rhythm.wake)) 起")
        case .busy: doing ?? String(localized: "在忙")
        case .free: doing ?? String(localized: "有空")
        }
        let speed: String = switch status {
        case .asleep: String(localized: "醒了才会回")
        case .busy: String(localized: "回得会慢一点")
        case .free: String(localized: "很快就回")
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("right now · \(Fmt.hm.string(from: .now))").font(Typo.serif(14).italic()).foregroundStyle(Palette.onNoir.opacity(0.6))
            Text(line).font(Typo.serif(17)).lineSpacing(4).foregroundStyle(Palette.onNoir)
            Text(life.mood.isEmpty ? speed : "\(speed) · " + String(localized: "心情：\(life.mood)"))
                .font(.system(size: Typo.secondary)).foregroundStyle(Palette.onNoir.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.card + 4)
        .padding(.vertical, 18)
        .background(Palette.noir, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private func planRow(_ item: World.PlanItem, index: Int) -> some View {
        let t = Clock.hour()
        let now = World.current(of: persona.id)?.at == item.at
        let past = item.at < t && !now
        return HStack(spacing: Space.item) {
            Text(World.clock(item.at)).font(Typo.serif(14).italic()).foregroundStyle(now ? Palette.ink : Palette.inkSoft).frame(width: 52, alignment: .leading)
            Circle().fill(now ? Palette.danger : past ? Palette.faint : Palette.ink).frame(width: now ? 9 : 7, height: now ? 9 : 7)
            Text(item.what).font(.system(size: 15, weight: now ? .medium : .regular)).foregroundStyle(past ? Palette.inkSoft : Palette.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.card)
        .frame(minHeight: 46)
    }

    /// 选几点（半小时一格）
    private func hourMenu(_ value: Binding<Double>) -> some View {
        Menu {
            ForEach(0..<48, id: \.self) { i in
                let h = Double(i) / 2
                Button(World.clock(h)) { value.wrappedValue = h }
            }
        } label: {
            MenuValue(text: World.clock(value.wrappedValue))
        }
    }
}

/// 编辑角色「记忆」一章里的「你们」：你们是什么关系、认识多少天、TA 怎么叫你、是不是在闹别扭
struct YouTwoGroup: View {
    let persona: Persona

    var body: some View {
        let days = max(1, Calendar.current.dateComponents([.day], from: persona.createdAt.startOfDay, to: Date.now.startOfDay).day ?? 0)
        let r = HumanTouch.relation(persona)
        SettingsGroup(title: "你们") {
            // 关系在「世界」里写，这里只看
            if let text = relationText {
                SettingRow(title: "关系") {
                    Text(text).font(.system(size: 14)).foregroundStyle(Palette.inkSoft).lineLimit(1)
                }
            }
            SettingRow(title: "认识", subtitle: r.nickname.isEmpty ? nil : String(localized: "TA 叫你「\(r.nickname)」")) {
                Text("Day \(days)").font(Typo.serif(15).italic()).foregroundStyle(Palette.inkSoft)
            }
            if r.sulking {
                SettingRow(title: "正在闹别扭") { Text("哄哄 TA").font(.system(size: 14)).foregroundStyle(Palette.inkSoft) }
            }
        }
    }

    /// 世界里写的「你和 TA」那一段关系
    private var relationText: String? {
        World.state.relations.first { ($0.a == nil && $0.b == persona.id) || ($0.b == nil && $0.a == persona.id) }?.text
    }
}
