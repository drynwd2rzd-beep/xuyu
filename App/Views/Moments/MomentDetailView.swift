import SwiftUI
import SwiftData

/// 一条动态的详情（照设计稿）：帖子本身，下面是全部评论，按对话排，回复往里缩一格；
/// 最下面是写评论的框（点 TA 的某条评论就是回复 TA）。从信息流点帖子、点评论进来
struct MomentDetailView: View {
    let moment: Moment
    /// 进来就弹出键盘写评论（在信息流里点的是评论按钮）
    var commenting = false
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(RelayClient.self) private var relay
    @Environment(Router.self) private var router
    @Query private var personas: [Persona]
    @Query private var photos: [AlbumPhoto]
    @State private var replyTo: MomentComment?
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        let people = Dictionary(personas.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pictures = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        TimelineView(.everyMinute) { ctx in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PostView(moment: moment, people: people, pictures: pictures, now: ctx.date,
                             onOpen: { comment in if comment { typing = true } },
                             onProfile: { router.open(.momentsOf($0)) })
                    thread(people: people, now: ctx.date)
                }
                .padding(.bottom, Space.bottom)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { replyBar(people: people) }
        .background(Palette.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if commenting { typing = true } }
    }

    private var header: some View {
        ZStack {
            Text("动态")
                .font(.system(size: Typo.label))
                .tracking(Typo.labelTracking)
                .foregroundStyle(Palette.inkSoft)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: Icon.back, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: Space.control, height: Space.control)
                }
                .accessibilityLabel("返回")
                Spacer()
            }
        }
        .padding(.horizontal, Space.tight)
        .background(.ultraThinMaterial)
    }

    // MARK: - 评论

    @ViewBuilder
    private func thread(people: [UUID: Persona], now: Date) -> some View {
        let comments = moment.visibleComments(at: now)
        HStack(alignment: .firstTextBaseline, spacing: Space.tight) {
            Text("评论").font(.system(size: Typo.caption)).tracking(Typo.labelTracking)
            Text(verbatim: "\(comments.count)").font(Typo.serif(Typo.label)).foregroundStyle(Palette.ink2)
        }
        .foregroundStyle(Palette.inkSoft)
        .padding(.horizontal, Space.card)
        .padding(.top, Space.tight)
        .padding(.bottom, Space.tiny)
        if comments.isEmpty && !MomentsEngine.shared.replying.contains(moment.id) {
            Text("还没有评论。")
                .font(Typo.serif(Typo.label))
                .foregroundStyle(Palette.inkSoft)
                .padding(.horizontal, Space.card)
                .padding(.top, Space.item)
        }
        ForEach(comments) { c in
            CommentRow(comment: c, people: people, now: now) {
                guard c.personaID != nil else { return }
                replyTo = c
                typing = true
            }
        }
        if MomentsEngine.shared.replying.contains(moment.id), let id = moment.personaID, let author = people[id] {
            HStack(spacing: Space.item) {
                AvatarView(persona: author, size: AvatarSize.comment)
                TypingDots(bare: true).scaleEffect(0.8, anchor: .leading)
            }
            .padding(.horizontal, Space.card)
            .padding(.vertical, Space.tight)
            .transition(.opacity)
        }
    }

    private func replyBar(people: [UUID: Persona]) -> some View {
        let name = replyTo?.personaID.flatMap { people[$0]?.name }
        return HStack(spacing: Space.item) {
            UserAvatar(size: AvatarSize.comment)
            HStack(spacing: Space.tiny) {
                TextField(name.map { String(localized: "回复 \($0)…") } ?? String(localized: "评论…"), text: $draft, axis: .vertical)
                    .font(.system(size: Typo.body))
                    .lineLimit(1...4)
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.vertical, Space.tight)
                    .padding(.leading, Space.section)
                let ready = !draft.trimmed.isEmpty
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: Icon.sendGlyph, weight: .bold))
                        .foregroundStyle(Palette.inkInverse)
                        .frame(width: Icon.send, height: Icon.send)
                        .background(Palette.ink, in: Circle())
                        .scaleEffect(ready ? 1 : 0.01)
                        .opacity(ready ? 1 : 0)
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(!ready)
                .accessibilityLabel("发送")
                .animation(Motion.bubblePop, value: ready)
                .padding(.trailing, Space.tiny)
            }
            .overlay(Capsule().strokeBorder(Palette.inkSoft.opacity(0.35), lineWidth: 0.5))
        }
        .padding(.horizontal, Space.item)
        .padding(.vertical, Space.tight)
        .background(.ultraThinMaterial)
        .onChange(of: typing) { _, on in
            // 键盘收起、又没写字：不再是回复某个人
            if !on && draft.trimmed.isEmpty { replyTo = nil }
        }
    }

    private func send() {
        guard !draft.trimmed.isEmpty else { return }
        MomentsEngine.shared.comment(draft, on: moment, replyTo: replyTo, context: context, relay: relay)
        draft = ""
        replyTo = nil
        typing = false
    }
}

/// 详情里的一条评论：头像、名字、时间，下面是字（TA 们的用宋体）；回复别人的往里缩一格、头像小一点。
/// 点 TA 的评论就是回复 TA；你自己的长按能删
private struct CommentRow: View {
    let comment: MomentComment
    let people: [UUID: Persona]
    let now: Date
    let onReply: () -> Void
    @Environment(\.modelContext) private var context

    var body: some View {
        let who = comment.personaID.flatMap { people[$0] }
        let mine = comment.personaID == nil
        let name = mine ? PromptParts.userName : who?.name ?? String(localized: "已删除的角色")
        let to = comment.replyToMe ? PromptParts.userName : comment.replyTo.map { people[$0]?.name ?? String(localized: "已删除的角色") }
        let nested = to != nil
        Button(action: onReply) {
            HStack(alignment: .top, spacing: Space.item) {
                Group {
                    if mine { UserAvatar(size: nested ? AvatarSize.reply : AvatarSize.comment) }
                    else { AvatarView(persona: who, size: nested ? AvatarSize.reply : AvatarSize.comment) }
                }
                VStack(alignment: .leading, spacing: Space.tiny) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.tight) {
                        Text(verbatim: name).font(.system(size: Typo.label, weight: .medium)).foregroundStyle(Palette.ink)
                        if let to { Text("回复 \(to)").font(.system(size: Typo.caption)).foregroundStyle(Palette.inkSoft) }
                        Text(verbatim: PostTime.label(comment.createdAt, now: now))
                            .font(.system(size: Typo.caption)).foregroundStyle(Palette.inkSoft)
                    }
                    Text(verbatim: comment.text)
                        .font(mine ? .system(size: Typo.body) : Typo.serif(Typo.body))
                        .lineSpacing(Space.tiny)
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, nested ? AvatarSize.replyIndent : 0)
            .padding(.horizontal, Space.card)
            .padding(.vertical, Space.tight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .riseIn(fresh: now.timeIntervalSince(comment.createdAt) < 3)
        .contextMenu {
            if mine {
                Button(role: .destructive) {
                    withAnimation(Motion.spring) { context.delete(comment) }
                    context.persist()
                } label: { Label("删除", systemImage: "trash") }
            }
        }
    }
}
