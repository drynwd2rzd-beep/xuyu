import SwiftUI
import SwiftData

/// 角色与群聊：所有角色（点进去是编辑角色的五章）、所有群聊，新建角色、新建群聊
struct PersonasView: View {
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @Query(filter: #Predicate<Conversation> { $0.isGroup }, sort: \Conversation.createdAt) private var groups: [Conversation]
    @State private var newGroup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                VStack(alignment: .leading, spacing: Space.tight) {
                    SectionLabel(text: "角色")
                    VStack(spacing: 0) {
                        ForEach(personas) { p in
                            Button { router.open(.persona(p.id)) } label: {
                                HStack(spacing: Space.item) {
                                    AvatarView(persona: p, size: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(p.name).font(Typo.serif(16.5, .medium)).foregroundStyle(Palette.ink)
                                            EngineLogo(engine: p.engine, size: 12)
                                        }
                                        if !p.bio.isEmpty {
                                            Text(p.bio).font(.system(size: 13)).foregroundStyle(Palette.inkSoft).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Chevron()
                                }
                                .padding(.horizontal, Space.card)
                                .frame(height: Space.rowTall + 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableRowStyle())
                            if p.id != personas.last?.id { Hairline(inset: 68) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .card()
                }

                if !groups.isEmpty {
                    VStack(alignment: .leading, spacing: Space.tight) {
                        SectionLabel(text: "群聊")
                        VStack(spacing: 0) {
                            ForEach(groups) { g in
                                Button { router.open(.chat(g.id)) } label: {
                                    SettingRow(title: g.displayTitle(personas.filter { g.memberIDs.contains($0.id) })) {
                                        Text("\(g.memberIDs.count) 位").font(.system(size: 13)).foregroundStyle(Palette.inkSoft)
                                        Chevron()
                                    }
                                }
                                .buttonStyle(PressableRowStyle())
                                if g.id != groups.last?.id { Hairline() }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .card()
                    }
                }

                HStack(spacing: Space.item) {
                    bigButton("新建角色", "person.badge.plus", action: createPersona)
                    bigButton("新建群聊", "person.3", action: { newGroup = true })
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .top, spacing: 0) { SubpageHeader(title: "角色与群聊") }
        .background(Palette.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $newGroup) {
            NewGroupSheet { convo in router.open(.chat(convo.id)) }
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
    }

    private func bigButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity)
                .frame(height: Space.row)
                .card()
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func createPersona() {
        let p = Persona(name: "新角色", engine: .claude, tint: 0xD8C5AE)
        p.sortIndex = (personas.map(\.sortIndex).max() ?? 0) + 1
        context.insert(p)
        _ = context.chat(for: p)
        context.persist()
        router.open(.persona(p.id))
    }
}

struct NewGroupSheet: View {
    let onCreate: (Conversation) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @State private var title = ""
    @State private var selected: [UUID] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                HStack {
                    Button("取消") { dismiss() }.foregroundStyle(Palette.inkSoft)
                    Spacer()
                    Text("新建群聊").font(Typo.serif(18, .medium)).foregroundStyle(Palette.ink)
                    Spacer()
                    Button("创建") {
                        let convo = Conversation(title: title.trimmed, isGroup: true, memberIDs: selected)
                        context.insert(convo)
                        context.persist()
                        dismiss()
                        onCreate(convo)
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.ink)
                    .disabled(selected.count < 2)
                }
                TextField("群聊名称", text: $title)
                    .font(.system(size: 16))
                    .padding(.horizontal, Space.card)
                    .frame(height: Space.row)
                    .card()
                VStack(spacing: 0) {
                    ForEach(personas) { p in
                        Button {
                            if let i = selected.firstIndex(of: p.id) { selected.remove(at: i) } else { selected.append(p.id) }
                        } label: {
                            HStack(spacing: Space.item) {
                                AvatarView(persona: p, size: 36)
                                Text(p.name).font(.system(size: 16)).foregroundStyle(Palette.ink)
                                Spacer()
                                Image(systemName: selected.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 21))
                                    .foregroundStyle(selected.contains(p.id) ? Palette.ink : Palette.faint)
                            }
                            .padding(.horizontal, Space.card)
                            .frame(height: Space.row + 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableRowStyle())
                        if p.id != personas.last?.id { Hairline(inset: 64) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .card()
                .sensoryFeedback(.selection, trigger: selected)
            }
            .padding(Space.page)
        }
    }
}
