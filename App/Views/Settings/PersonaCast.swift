import SwiftUI
import SwiftData

/// 设置首页「AI」下面那一排角色卡（照设计稿）：每位一张浅灰的竖卡，中间一团 TA 心情颜色的光，
/// 下面是名字和用的引擎；最后一张是「新角色」。点卡片进编辑角色
struct PersonaCast: View {
    @Environment(Router.self) private var router
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @Query(sort: \DiaryEntry.day, order: .reverse) private var entries: [DiaryEntry]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.tight) {
                ForEach(personas) { p in
                    Button { router.open(.persona(p.id)) } label: { card(p) }
                        .buttonStyle(ScaleButtonStyle())
                        .accessibilityLabel(Text("编辑 \(p.name)"))
                }
                Button { router.open(.personas) } label: {
                    VStack(spacing: Space.tiny) {
                        Image(systemName: "plus").font(.system(size: Typo.heading, weight: .ultraLight))
                        Text("新角色").font(.system(size: Typo.caption)).tracking(Typo.labelTracking)
                    }
                    .foregroundStyle(Palette.inkSoft)
                    .frame(width: Self.width, height: Self.height)
                    .overlay(RoundedRectangle(cornerRadius: Radius.cast, style: .continuous)
                        .strokeBorder(Palette.inkSoft.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(.horizontal, Space.tight)
        }
    }

    private func card(_ p: Persona) -> some View {
        let mood = entries.first { $0.author == .ai && $0.personaID == p.id && !$0.mood.isEmpty }?.mood ?? ""
        return ZStack {
            MoodGlow(glow: MoodTint.glow(for: mood), size: Self.glow)
                .offset(y: Self.glowLift)
            VStack(spacing: Self.nameGap) {
                Spacer()
                Text(verbatim: p.name)
                    .font(.system(size: Typo.label))
                    .tracking(Typo.labelTracking)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(verbatim: p.engine.label)
                    .font(.system(size: Typo.caption))
                    .foregroundStyle(Palette.inkSoft)
            }
            .padding(.bottom, Space.section)
        }
        .frame(width: Self.width, height: Self.height)
        .background(Palette.card)
        .clipShape(.rounded(Radius.cast))
    }

    /// 卡片的大小（照设计稿 104 × 148）
    private static let width: CGFloat = 104
    private static let height: CGFloat = 148
    /// 光团的大小、往上挪多少，名字和引擎之间隔多少
    private static let glow: CGFloat = 114
    private static let glowLift: CGFloat = -15
    private static let nameGap: CGFloat = 2
}
