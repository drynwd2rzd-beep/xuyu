import SwiftUI
import SwiftData

/// 帖子里铺满宽的照片：4:5，统一调色，多张能左右翻（右上角「1/3」，下面小圆点）；双击喜欢，心在中间冒一下
struct PostPhotos: View {
    let photos: [AlbumPhoto]
    let onDoubleTap: () -> Void
    @State private var page = 0
    @State private var pop = false
    /// 下面小圆点的大小
    private static let dot: CGFloat = 5

    var body: some View {
        TabView(selection: $page) {
            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                PhotoFill(photo: photo).tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .aspectRatio(4 / 5, contentMode: .fit)
        .background(Palette.card)
        .overlay(alignment: .topTrailing) {
            if photos.count > 1 {
                Text(verbatim: "\(page + 1)/\(photos.count)")
                    .font(Typo.serif(Typo.label))
                    .monospacedDigit()
                    .foregroundStyle(Palette.onPhoto)
                    .padding(.horizontal, Space.tight)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(Space.item)
            }
        }
        .overlay(alignment: .bottom) {
            if photos.count > 1 {
                HStack(spacing: 4) {
                    ForEach(photos.indices, id: \.self) { i in
                        Capsule().fill(Palette.onPhoto.opacity(i == page ? 1 : 0.5))
                            .frame(width: i == page ? Space.item : Self.dot, height: Self.dot)
                    }
                }
                .animation(Motion.snappy, value: page)
                .padding(.bottom, Space.item)
            }
        }
        .overlay {
            Image(systemName: "heart.fill")
                .font(.system(size: Icon.heartPop))
                .foregroundStyle(Palette.onPhoto)
                .scaleEffect(pop ? 1 : 0.6)
                .opacity(pop ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onTapGesture(count: 2) {
            onDoubleTap()
            withAnimation(Motion.bubblePop) { pop = true }
            Task {
                try? await Task.sleep(for: Motion.menuSettle)
                withAnimation(Motion.fade) { pop = false }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: pop) { _, new in new }
        .accessibilityLabel(Text("\(photos.count) 张照片"))
    }
}

/// 一张照片铺满它的格子；按显示尺寸解码（CONC-2），解好之前是浅灰
struct PhotoFill: View {
    let photo: AlbumPhoto
    @State private var image: UIImage?
    /// 铺满屏幕宽的 4:5：宽 430 点 × 3 倍屏
    private static let pixel = 1600

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().graded().transition(.opacity)
                }
            }
            .clipped()
            .task(id: photo.id) {
                let decoded = cachedImage(photo.data, key: photo.id.uuidString, maxPixel: Self.pixel)
                withAnimation(Motion.glide) { image = decoded }
            }
    }
}

/// 喜欢、评论两个按钮，后面是「谁喜欢了」。compact 是纯文字帖子用的小一号、灰色的样子
struct PostActions: View {
    let moment: Moment
    let people: [UUID: Persona]
    var compact = false
    let onComment: () -> Void
    @Environment(\.modelContext) private var context
    @State private var burst = false

    var body: some View {
        let likers = moment.likedBy.compactMap { people[$0]?.name } + (moment.likedByMe ? [PromptParts.userName] : [])
        let count = moment.visibleComments().count
        HStack(spacing: compact ? Space.group : Space.tight) {
            Button {
                if !moment.likedByMe { burst.toggle() }
                MomentsEngine.shared.toggleLike(moment, context: context)
            } label: {
                label(moment.likedByMe ? "heart.fill" : "heart", compact ? (likers.isEmpty ? nil : likers.count) : nil)
                    .foregroundStyle(moment.likedByMe ? Palette.heart : (compact ? Palette.inkSoft : Palette.ink))
                    .symbolEffect(.bounce, value: burst)
            }
            .accessibilityLabel(moment.likedByMe ? "取消喜欢" : "喜欢")
            .sensoryFeedback(.impact(weight: .light), trigger: moment.likedByMe)
            Button(action: onComment) {
                label("bubble.right", compact && count > 0 ? count : nil)
                    .foregroundStyle(compact ? Palette.inkSoft : Palette.ink)
            }
            .accessibilityLabel("评论")
            if !compact, !likers.isEmpty {
                Text(likeText(likers)).font(.system(size: Typo.label)).foregroundStyle(Palette.ink2).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
    }

    private func label(_ symbol: String, _ number: Int?) -> some View {
        HStack(spacing: Space.tiny) {
            Image(systemName: symbol).font(.system(size: compact ? Icon.tweetAction : Icon.postAction))
            if let number { Text(verbatim: "\(number)").font(.system(size: Typo.label)).monospacedDigit() }
        }
        .frame(minWidth: Space.control, minHeight: Space.control)
        .contentShape(Rectangle())
    }

    /// 点赞那一行的字：一个人、两个人、更多人各一种说法
    private func likeText(_ all: [String]) -> String {
        if all.count == 1 { return String(localized: "\(all[0]) 喜欢") }
        if all.count == 2 { return String(localized: "\(all[0]) 和 \(all[1]) 喜欢") }
        return String(localized: "\(all[0]) 等 \(all.count) 人喜欢")
    }
}

/// 帖子下面的前两条评论和「查看全部 N 条评论」；TA 正在回时有跳动的小点
struct CommentPreview: View {
    let moment: Moment
    let people: [UUID: Persona]
    let now: Date
    let onAll: () -> Void
    private static let shown = 2

    var body: some View {
        let comments = moment.visibleComments(at: now)
        let replying = MomentsEngine.shared.replying.contains(moment.id)
        if !comments.isEmpty || replying {
            VStack(alignment: .leading, spacing: Space.tiny) {
                if comments.count > Self.shown {
                    Button(action: onAll) {
                        Text("查看全部 \(comments.count) 条评论").font(.system(size: Typo.label)).foregroundStyle(Palette.inkSoft)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(comments.suffix(Self.shown)) { c in
                    let who = c.personaID == nil ? PromptParts.userName : people[c.personaID ?? UUID()]?.name ?? String(localized: "已删除的角色")
                    (Text(verbatim: who + "  ").fontWeight(.medium) + Text(verbatim: c.text))
                        .font(.system(size: Typo.label))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                        .riseIn(fresh: now.timeIntervalSince(c.createdAt) < 3)
                }
                if replying { TypingDots(bare: true).scaleEffect(0.7, anchor: .leading) }
            }
        }
    }
}
