import SwiftUI
import SwiftData

/// 一条动态的卡片
struct MomentCard: View {
    let moment: Moment
    let people: [UUID: Persona]
    let pictures: [UUID: AlbumPhoto]
    let now: Date
    let replying: Bool
    let onComment: (MomentComment?) -> Void
    let onProfile: (UUID) -> Void
    @Environment(\.modelContext) private var context
    @State private var burst = false

    private var author: Persona? { moment.personaID.flatMap { people[$0] } }
    /// 你发的用你的称呼；作者是查不到的角色（已经删了）时写「已删除的角色」，不能退回成你的名字
    private var name: String { moment.isMine ? PromptParts.userName : author?.name ?? String(localized: "已删除的角色") }

    var body: some View {
        let comments = moment.visibleComments(at: now)
        VStack(alignment: .leading, spacing: Space.item) {
            top
            text
            if moment.voice != nil { VoiceMomentButton(moment: moment) }
            let shots = moment.photoIDs.compactMap { pictures[$0] }
            if !shots.isEmpty { PolaroidStack(photos: shots) }
            actions
            if !comments.isEmpty || replying {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(comments) { c in commentRow(c) }
                    if replying, let author { typingRow(author) }
                }
                .padding(.top, Space.item)
                .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
            }
        }
        .padding(.horizontal, Space.card + 2)
        .padding(.top, Space.card + 2)
        .padding(.bottom, Space.item)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: Radius.card + 2)
        .contextMenu {
            if moment.isMine {
                Button(role: .destructive) { MomentsEngine.shared.delete(moment, context: context) } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    private var top: some View {
        HStack(spacing: 10) {
            Button { if let id = moment.personaID { onProfile(id) } } label: {
                if moment.isMine { UserAvatar(size: 36) } else { AvatarView(persona: author, size: 36) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(name) 的主页"))
            Text(name).font(Typo.serif(16.5, .medium)).foregroundStyle(Palette.ink)
            if !moment.mood.isEmpty { MoodTag(text: moment.mood) }
            Spacer(minLength: 0)
            Text(Fmt.hm.string(from: moment.createdAt)).font(.system(size: 12)).foregroundStyle(Palette.faint)
        }
    }

    /// 短短一句用大号衬线字，像一句引言；长的用正文
    @ViewBuilder
    private var text: some View {
        if moment.text.count <= 16 && !moment.text.contains("\n") {
            Text(moment.text).font(Typo.serif(23)).lineSpacing(4).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(moment.text).font(.system(size: Typo.body)).lineSpacing(6).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 喜欢

    private var actions: some View {
        let likers = moment.likedBy.compactMap { people[$0] }
        return HStack(spacing: Space.tight) {
            if !likers.isEmpty || moment.likedByMe {
                HStack(spacing: -7) {
                    ForEach(likers.prefix(3)) { AvatarView(persona: $0, size: 22, ring: true) }
                    if moment.likedByMe { UserAvatar(size: 22) }
                }
                Text(likeText(likers.map(\.name))).font(.system(size: Typo.secondary)).foregroundStyle(Palette.inkSoft).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                if !moment.likedByMe { burst.toggle() }
                MomentsEngine.shared.toggleLike(moment, context: context)
            } label: {
                Image(systemName: moment.likedByMe ? "heart.fill" : "heart")
                    .font(.system(size: 18))
                    .foregroundStyle(moment.likedByMe ? Palette.danger : Palette.ink)
                    .symbolEffect(.bounce, value: burst)
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(moment.likedByMe ? "取消喜欢" : "喜欢")
            .sensoryFeedback(.impact(weight: .light), trigger: moment.likedByMe)
            Button { onComment(nil) } label: {
                Image(systemName: "bubble.right")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("评论")
        }
        .padding(.trailing, -10)
    }

    /// 点赞那一行的字：一个人、两个人、更多人各一种说法
    private func likeText(_ names: [String]) -> String {
        let all = names + (moment.likedByMe ? [PromptParts.userName] : [])
        if all.count == 1 { return String(localized: "\(all[0]) 喜欢") }
        if all.count == 2 { return String(localized: "\(all[0]) 和 \(all[1]) 喜欢") }
        return String(localized: "\(all[0]) 等 \(all.count) 人喜欢")
    }

    // MARK: - 评论

    /// 一条评论：点 TA 的评论可以回复；你自己的长按能删
    private func commentRow(_ c: MomentComment) -> some View {
        let who = c.personaID.flatMap { people[$0] }
        let whoName = c.personaID == nil ? PromptParts.userName : who?.name ?? String(localized: "已删除的角色")
        let to = c.replyToMe ? PromptParts.userName : c.replyTo.map { people[$0]?.name ?? String(localized: "已删除的角色") }
        return Button { if c.personaID != nil { onComment(c) } } label: {
            HStack(alignment: .top, spacing: 9) {
                if c.personaID == nil { UserAvatar(size: 24) } else { AvatarView(persona: who, size: 24) }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(whoName).font(.system(size: Typo.secondary, weight: .semibold)).foregroundStyle(Palette.ink)
                        if let to { Text("回复 \(to)").font(.system(size: Typo.secondary)).foregroundStyle(Palette.inkSoft) }
                    }
                    Text(c.text).font(.system(size: 14.5)).lineSpacing(3).foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, to == nil ? 0 : 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .riseIn(fresh: now.timeIntervalSince(c.createdAt) < 3)
        .contextMenu {
            if c.personaID == nil {
                Button(role: .destructive) {
                    withAnimation(Motion.spring) { context.delete(c) }
                    context.persist()
                } label: { Label("删除", systemImage: "trash") }
            }
        }
    }

    /// TA 正在回评论：头像加跳动的小点
    private func typingRow(_ persona: Persona) -> some View {
        HStack(spacing: 9) {
            AvatarView(persona: persona, size: 24)
            TypingDots(bare: false)
        }
        .padding(.leading, 20)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
