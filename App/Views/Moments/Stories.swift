import SwiftUI
import SwiftData

/// 动态顶上一排快拍（照 Instagram）：第一个是你（点一下发动态），后面是最近一天发过照片的 TA 们，
/// 有你没看过的就套一圈渐变的环。点开全屏看
struct StoriesRow: View {
    let stories: [Story]
    let seenAt: Double
    let onCompose: () -> Void
    let onOpen: (Story) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.section) {
                Button(action: onCompose) {
                    face(fresh: false, label: PromptParts.userName) {
                        UserAvatar(size: AvatarSize.storyFace)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "plus")
                                    .font(.system(size: Typo.caption, weight: .bold))
                                    .foregroundStyle(Palette.inkInverse)
                                    .frame(width: Icon.storyPlus, height: Icon.storyPlus)
                                    .background(Palette.ink, in: Circle())
                                    .overlay(Circle().strokeBorder(Palette.paper, lineWidth: 2.5))
                            }
                    }
                }
                .accessibilityLabel("发动态")
                ForEach(stories) { story in
                    Button { onOpen(story) } label: {
                        face(fresh: story.latest.timeIntervalSince1970 > seenAt, label: story.persona.name) {
                            AvatarView(persona: story.persona, size: AvatarSize.storyFace)
                        }
                    }
                    .accessibilityLabel(Text("\(story.persona.name) 的快拍"))
                }
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, Space.page)
            .padding(.vertical, Space.tiny)
        }
    }

    /// 头像外面一圈：没看过是渐变环，看过是一圈细灰线；下面是名字
    private func face<Face: View>(fresh: Bool, label: String, @ViewBuilder _ face: () -> Face) -> some View {
        VStack(spacing: Space.tight) {
            face()
                .padding(Space.tiny)
                .overlay {
                    if fresh {
                        Circle().strokeBorder(AngularGradient(colors: [Palette.Mood.bright.m1, Palette.Mood.tender.m1,
                                                                       Palette.Mood.tired.m1, Palette.Mood.bright.m1],
                                                              center: .center), lineWidth: 2)
                    } else {
                        Circle().strokeBorder(Palette.inkSoft.opacity(0.3), lineWidth: 1)
                    }
                }
                .frame(width: AvatarSize.story, height: AvatarSize.story)
            Text(verbatim: label)
                .font(.system(size: Typo.caption))
                .tracking(Typo.tracking)
                .foregroundStyle(fresh ? Palette.ink : Palette.inkSoft)
                .lineLimit(1)
                .frame(maxWidth: AvatarSize.storyLabel)
        }
    }
}

/// 一位角色的快拍：最近一天发的、带照片的动态，按时间排
struct Story: Identifiable {
    let persona: Persona
    /// 每一张：照片和它那条动态
    let frames: [(moment: Moment, photo: AlbumPhoto)]
    var id: UUID { persona.id }
    var latest: Date { frames.last?.moment.createdAt ?? .distantPast }

    /// 从全部动态里挑出每个人最近一天的快拍；最新发的人排在前面
    static func make(_ moments: [Moment], people: [UUID: Persona], pictures: [UUID: AlbumPhoto], now: Date) -> [Story] {
        let since = now.addingTimeInterval(-Limits.Timing.storyWindow)
        var byPerson: [UUID: [(moment: Moment, photo: AlbumPhoto)]] = [:]
        for m in moments where m.createdAt <= now && m.createdAt >= since {
            guard let id = m.personaID, people[id] != nil else { continue }
            for pid in m.photoIDs { if let p = pictures[pid] { byPerson[id, default: []].append((moment: m, photo: p)) } }
        }
        return byPerson.compactMap { id, frames in
            people[id].map { Story(persona: $0, frames: frames.sorted { $0.moment.createdAt < $1.moment.createdAt }) }
        }
        .sorted { $0.latest > $1.latest }
    }
}

/// 全屏看快拍：顶上一条条进度，点右半边下一张、左半边上一张，按住暂停，看完自己关
struct StoryViewer: View {
    let story: Story
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var progress: Double = 0
    @State private var holding = false

    var body: some View {
        let frame = story.frames[min(index, story.frames.count - 1)]
        ZStack {
            Palette.listenNight.ignoresSafeArea()
            PhotoFill(photo: frame.photo)
                .id(frame.photo.id)
                .transition(.opacity)
                .ignoresSafeArea()
            LinearGradient(stops: [
                .init(color: Palette.photoShade.opacity(0.45), location: 0),
                .init(color: Palette.photoShade.opacity(0), location: 0.22),
                .init(color: Palette.photoShade.opacity(0), location: 0.62),
                .init(color: Palette.photoShade.opacity(0.55), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { step(-1) }
                Color.clear.contentShape(Rectangle()).onTapGesture { step(1) }
            }
            .onLongPressGesture(minimumDuration: 0.2, perform: {}, onPressingChanged: { holding = $0 })
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.item) {
                bars
                HStack(spacing: Space.item) {
                    AvatarView(persona: story.persona, size: AvatarSize.post)
                    Text(verbatim: story.persona.name).font(.system(size: Typo.label, weight: .medium))
                    Text(verbatim: PostTime.label(frame.moment.createdAt, now: .now))
                        .font(.system(size: Typo.caption)).opacity(0.7)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: Icon.plus, weight: .medium))
                            .frame(width: Space.control, height: Space.control)
                    }
                    .accessibilityLabel("关闭")
                }
                Spacer()
                if !frame.moment.text.trimmed.isEmpty {
                    Text(verbatim: frame.moment.text.trimmed)
                        .font(Typo.serif(Typo.Book.post))
                        .lineSpacing(Typo.Book.proseSpacing)
                        .lineLimit(5)
                }
            }
            .foregroundStyle(Palette.onPhoto)
            .padding(.horizontal, Space.card)
            .padding(.vertical, Space.page)
        }
        .animation(Motion.fade, value: index)
        .statusBarHidden()
        .task(id: index) { await play() }
        .accessibilityAction(named: Text("下一张")) { step(1) }
        .accessibilityAction(named: Text("上一张")) { step(-1) }
    }

    private var bars: some View {
        HStack(spacing: Space.tiny) {
            ForEach(story.frames.indices, id: \.self) { i in
                GeometryReader { geo in
                    Capsule().fill(Palette.onPhoto.opacity(0.32))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Palette.onPhoto)
                                .frame(width: geo.size.width * (i < index ? 1 : i == index ? progress : 0))
                        }
                }
                .frame(height: 2)
            }
        }
    }

    /// 一张放 storyFrame 秒，按住时停下；放完自动到下一张
    private func play() async {
        progress = 0
        let tick = Duration.milliseconds(50)
        let total = Limits.Timing.storyFrame
        var elapsed = 0.0
        while elapsed < total, !Task.isCancelled {
            try? await Task.sleep(for: tick)
            if !holding { elapsed += 0.05 }
            progress = elapsed / total
        }
        guard !Task.isCancelled else { return }
        step(1)
    }

    private func step(_ delta: Int) {
        let next = index + delta
        if next >= story.frames.count { dismiss() } else { index = max(0, next) }
    }
}
