import SwiftUI
import SwiftData
import PhotosUI

/// 动态：按天分段，每条一张卡片（拍立得配图、心情、语音、喜欢、评论）。
/// 点评论或某条评论，底下弹出输入框；右上角的笔发你自己的动态。
/// 卡片见 MomentCard，配图和语音见 Polaroid，发动态见 MomentComposer
struct MomentsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(RelayClient.self) private var relay
    @Environment(Router.self) private var router
    @Query(sort: \Moment.createdAt, order: .reverse) private var moments: [Moment]
    @Query private var personas: [Persona]
    @Query private var photos: [AlbumPhoto]
    @AppStorage(Prefs.momentsSeenAt) private var seenAt = 0.0
    @State private var target: CommentTarget?
    @State private var draft = ""
    @State private var composing = false
    @FocusState private var typing: Bool
    /// 底部的 Moments 页（没有返回键）；从角色主页点进来时是推进来的一页
    let root: Bool

    init(root: Bool = false) {
        self.root = root
    }

    /// 正在评论哪条动态、回复哪条评论
    struct CommentTarget {
        let moment: Moment
        let comment: MomentComment?
    }

    var body: some View {
        let people = Dictionary(personas.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pictures = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        TimelineView(.everyMinute) { ctx in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(ctx.date)
                    let days = Self.days(moments.filter { $0.createdAt <= ctx.date })
                    if days.isEmpty {
                        Text("TA 们发的动态会出现在这里。")
                            .font(Typo.serif(16).italic())
                            .foregroundStyle(Palette.inkSoft)
                            .padding(.horizontal, Space.page + 2)
                            .padding(.top, 40)
                    }
                    ForEach(days, id: \.day) { day in
                        DayDivider(label: Self.dayLabel(day.day, now: ctx.date))
                        VStack(spacing: Space.section) {
                            ForEach(day.items) { m in
                                MomentCard(moment: m, people: people, pictures: pictures, now: ctx.date,
                                           replying: MomentsEngine.shared.replying.contains(m.id),
                                           onComment: { startComment(on: m, replyTo: $0) },
                                           onProfile: { id in router.open(.momentsOf(id)) })
                            }
                        }
                        .padding(.horizontal, Space.page - 4)
                    }
                }
                .padding(.bottom, 120)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Palette.paper.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if target != nil { commentBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $composing) {
            MomentComposer()
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        // 底部这一页一直开着（只是看不见）：切进来、切走时才算看过
        .onAppear { if !root || router.tab == .moments { seenAt = Date.now.timeIntervalSince1970 } }
        .onDisappear { seenAt = Date.now.timeIntervalSince1970 }
        .onChange(of: router.tab) { old, new in
            if root && (old == .moments || new == .moments) { seenAt = Date.now.timeIntervalSince1970 }
        }
        .onChange(of: typing) { _, on in
            // 键盘收起、又没写字：输入框一起收起
            if !on && draft.trimmed.isEmpty { withAnimation(Motion.spring) { target = nil } }
        }
    }

    private func header(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !root {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("返回")
                    Spacer()
                    composeButton
                }
                .padding(.horizontal, Space.tight)
            }
            PageTitle(caption: Fmt.enLong.string(from: now), title: "Moments") {
                if root { composeButton.padding(.bottom, 4) }
            }
            .padding(.horizontal, Space.page)
            .padding(.top, root ? Space.top : 0)
        }
    }

    private var composeButton: some View {
        Button { composing = true } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 40, height: 40)
                .background {
                    Circle().fill(Palette.card).shadow(color: .black.opacity(0.05), radius: 6, y: 3)
                }
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 0.5))
                .contentShape(Circle().inset(by: -2))
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel("发动态")
    }

    private var commentBar: some View {
        let name = target.flatMap { t in (t.comment?.personaID ?? t.moment.personaID).flatMap { id in personas.first { $0.id == id }?.name } }
        return HStack(spacing: Space.tight) {
            TextField(name.map { String(localized: "回复 \($0)…") } ?? String(localized: "评论…"), text: $draft, axis: .vertical)
                .font(.system(size: Typo.body))
                .lineLimit(1...4)
                .focused($typing)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, Space.card)
                .padding(.vertical, 11)
                // 和聊天输入框同一个圆角：一行时是胶囊，多行时四角一样圆
                .background(Palette.card, in: RoundedRectangle(cornerRadius: Space.control / 2, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Space.control / 2, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.inkInverse)
                    .frame(width: 44, height: 44)
                    .background(Palette.ink, in: Circle())
            }
            .buttonStyle(ScaleButtonStyle())
            .opacity(draft.trimmed.isEmpty ? 0.35 : 1)
            .disabled(draft.trimmed.isEmpty)
            .accessibilityLabel("发送")
        }
        .padding(.horizontal, Space.item)
        .padding(.top, Space.tight)
        .padding(.bottom, Space.tight)
        .background(.ultraThinMaterial)
    }

    private func startComment(on moment: Moment, replyTo comment: MomentComment?) {
        withAnimation(Motion.spring) { target = CommentTarget(moment: moment, comment: comment) }
        typing = true
    }

    private func send() {
        guard let target, !draft.trimmed.isEmpty else { return }
        MomentsEngine.shared.comment(draft, on: target.moment, replyTo: target.comment, context: context, relay: relay)
        draft = ""
        typing = false
        withAnimation(Motion.spring) { self.target = nil }
    }

    struct Day {
        let day: Date
        let items: [Moment]
    }

    /// 按天分段，新的在前
    static func days(_ moments: [Moment]) -> [Day] {
        var result: [Day] = []
        for m in moments {
            let day = m.createdAt.startOfDay
            if let i = result.firstIndex(where: { $0.day == day }) {
                result[i] = Day(day: day, items: result[i].items + [m])
            } else {
                result.append(Day(day: day, items: [m]))
            }
        }
        return result
    }

    static func dayLabel(_ day: Date, now: Date) -> String {
        if day == now.startOfDay { return "Today" }
        if day == now.startOfDay.adding(days: -1) { return "Yesterday" }
        return Fmt.enLong.string(from: day)
    }
}

/// 一天的开头：斜体的日子，后面一条细线
struct DayDivider: View {
    let label: String

    var body: some View {
        HStack(spacing: Space.item) {
            Text(label).font(Typo.serif(17).italic()).foregroundStyle(Palette.ink2)
            Rectangle().fill(Palette.hairline).frame(height: 0.5)
        }
        .padding(.horizontal, Space.page + 2)
        .padding(.top, 26)
        .padding(.bottom, Space.item)
    }
}
