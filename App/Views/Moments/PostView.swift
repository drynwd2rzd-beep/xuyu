import SwiftUI
import SwiftData

/// 动态里的一条（照设计稿 moments.html）：带照片的像 Instagram——头像一行、照片铺满宽（能左右翻）、
/// 喜欢和评论、谁喜欢了、配文、前两条评论；纯文字的像 X——头像在左，字在右。
/// TA 们写的字用宋体，你写的用系统字。帖子之间不画线，靠留白分开。点一下进详情（评论都在那里）
struct PostView: View {
    let moment: Moment
    let people: [UUID: Persona]
    let pictures: [UUID: AlbumPhoto]
    let now: Date
    /// 点帖子：进详情；comment = true 时进去就弹出键盘写评论
    let onOpen: (_ comment: Bool) -> Void
    let onProfile: (UUID) -> Void
    @Environment(\.modelContext) private var context

    private var author: Persona? { moment.personaID.flatMap { people[$0] } }
    /// 你发的用你的称呼；作者是查不到的角色（已经删了）时写「已删除的角色」，不能退回成你的名字
    private var name: String { moment.isMine ? PromptParts.userName : author?.name ?? String(localized: "已删除的角色") }
    private var shots: [AlbumPhoto] { moment.photoIDs.compactMap { pictures[$0] } }

    var body: some View {
        Group {
            if shots.isEmpty { tweet } else { photoPost }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen(false) }
        .contextMenu {
            if moment.isMine {
                Button(role: .destructive) { MomentsEngine.shared.delete(moment, context: context) } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - 带照片的（Instagram）

    private var photoPost: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack(spacing: Space.item) {
                avatar(AvatarSize.post)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: name).font(.system(size: Typo.label, weight: .medium)).tracking(Typo.tracking)
                    if !moment.mood.isEmpty {
                        Text(verbatim: moment.mood).font(.system(size: Typo.caption)).foregroundStyle(Palette.inkSoft)
                    }
                }
                .foregroundStyle(Palette.ink)
                Spacer()
            }
            .padding(.horizontal, Space.card)
            PostPhotos(photos: shots) { like(only: true) }
            PostActions(moment: moment, people: people, onComment: { onOpen(true) })
                .padding(.horizontal, Space.tight)
            if !moment.text.trimmed.isEmpty {
                (Text(verbatim: name + "  ").font(.system(size: Typo.label, weight: .medium))
                 + Text(verbatim: moment.text.trimmed).font(textFont))
                    .lineSpacing(Space.tight)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.card)
            }
            CommentPreview(moment: moment, people: people, now: now) { onOpen(false) }
                .padding(.horizontal, Space.card)
            Text(verbatim: PostTime.label(moment.createdAt, now: now))
                .font(Typo.serif(Typo.label))
                .foregroundStyle(Palette.inkSoft)
                .padding(.horizontal, Space.card)
        }
        .padding(.bottom, Space.group)
    }

    // MARK: - 纯文字的（X）

    private var tweet: some View {
        HStack(alignment: .top, spacing: Space.item) {
            avatar(AvatarSize.tweet)
            VStack(alignment: .leading, spacing: Space.tight) {
                HStack(spacing: Space.tight) {
                    Text(verbatim: name).font(.system(size: Typo.label, weight: .medium)).tracking(Typo.tracking)
                        .foregroundStyle(Palette.ink)
                    if !moment.mood.isEmpty { MoodTag(text: moment.mood) }
                    Text(verbatim: PostTime.label(moment.createdAt, now: now))
                        .font(.system(size: Typo.caption)).foregroundStyle(Palette.inkSoft)
                }
                if !moment.text.trimmed.isEmpty {
                    Text(verbatim: moment.text.trimmed)
                        .font(textFont)
                        .lineSpacing(Space.tight)
                        .tracking(Typo.tracking)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if moment.voice != nil { VoiceMomentButton(moment: moment) }
                PostActions(moment: moment, people: people, compact: true, onComment: { onOpen(true) })
                    .padding(.leading, -Space.tight)
                CommentPreview(moment: moment, people: people, now: now) { onOpen(false) }
            }
        }
        .padding(.horizontal, Space.card)
        .padding(.bottom, Space.group)
    }

    // MARK: - 零件

    /// TA 们写的字用宋体，你写的用系统字
    private var textFont: Font {
        moment.isMine ? .system(size: Typo.body) : Typo.serif(Typo.body)
    }

    private func avatar(_ size: CGFloat) -> some View {
        Button { if let id = moment.personaID { onProfile(id) } } label: {
            if moment.isMine { UserAvatar(size: size) } else { AvatarView(persona: author, size: size) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(name) 的主页"))
    }

    /// 双击照片：喜欢（已经喜欢了就不取消，像 Instagram）
    private func like(only: Bool) {
        guard !(only && moment.likedByMe) else { return }
        MomentsEngine.shared.toggleLike(moment, context: context)
    }
}

/// 动态上的时间：今天的写钟点（5:23 PM，UI-12），昨天写 Yesterday，再早写日期
enum PostTime {
    static func label(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return Fmt.bubble.string(from: date) }
        if cal.isDate(date, inSameDayAs: now.adding(days: -1)) { return "Yesterday" }
        return Fmt.enMonthDay.string(from: date)
    }
}
