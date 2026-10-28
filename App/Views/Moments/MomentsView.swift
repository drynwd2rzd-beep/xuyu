import SwiftUI
import SwiftData
import PhotosUI

/// 动态：按天分段，每条一张卡片（拍立得配图、心情、语音、喜欢、评论）。
/// 点评论或某条评论，底下弹出输入框；右上角的笔发你自己的动态
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
        .onAppear { seenAt = Date.now.timeIntervalSince1970 }
        .onDisappear { seenAt = Date.now.timeIntervalSince1970 }
        .onChange(of: typing) { _, on in
            // 键盘收起、又没写字：输入框一起收起
            if !on && draft.trimmed.isEmpty { withAnimation(Motion.spring) { target = nil } }
        }
    }

    private func header(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("返回")
                Spacer()
                Button { composing = true } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 40, height: 40)
                        .background {
                            Circle().fill(Palette.card).shadow(color: .black.opacity(0.05), radius: 6, y: 3)
                        }
                        .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 0.5))
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel("发动态")
            }
            .padding(.horizontal, Space.tight)
            PageTitle(caption: Fmt.enLong.string(from: now), title: "Moments") { EmptyView() }
                .padding(.horizontal, Space.page)
        }
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
    private var name: String { author?.name ?? PromptBuilder.userName }

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

    private func likeText(_ names: [String]) -> String {
        let all = names + (moment.likedByMe ? [PromptBuilder.userName] : [])
        if all.count == 1 { return String(localized: "\(all[0]) 喜欢") }
        if all.count == 2 { return String(localized: "\(all[0]) 和 \(all[1]) 喜欢") }
        return String(localized: "\(all[0]) 等 \(all.count) 人喜欢")
    }

    private func commentRow(_ c: MomentComment) -> some View {
        let who = c.personaID.flatMap { people[$0] }
        let whoName = who?.name ?? PromptBuilder.userName
        let to = c.replyToMe ? PromptBuilder.userName : c.replyTo.flatMap { people[$0]?.name }
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

    private func typingRow(_ persona: Persona) -> some View {
        HStack(spacing: 9) {
            AvatarView(persona: persona, size: 24)
            TypingDots(bare: false)
        }
        .padding(.leading, 20)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// 语音动态：点一下播放，波形跟着走
struct VoiceMomentButton: View {
    let moment: Moment
    private var player: VoicePlayer { VoicePlayer.shared }

    var body: some View {
        let id = "moment-\(moment.id)"
        let playing = player.playing == id
        let data = moment.voice ?? Data()
        Button { player.toggle(id, data: data) } label: {
            HStack(spacing: Space.item) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.inkInverse)
                    .frame(width: 34, height: 34)
                    .background(Palette.ink, in: Circle())
                Waveform(seed: id, bars: 16, progress: playing ? player.progress : 0)
                Text(Self.length(player.duration(id, data: data)))
                    .font(.system(size: Typo.secondary).monospacedDigit())
                    .foregroundStyle(Palette.inkSoft)
            }
            .padding(.leading, 6)
            .padding(.trailing, Space.card)
            .frame(height: 46)
            .background(Palette.paper, in: Capsule())
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel(playing ? "暂停语音" : "播放语音")
    }

    static func length(_ seconds: TimeInterval) -> String {
        let s = max(1, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 一张拍立得：白边、圆角、微微倾斜；影子只在底板上
struct Polaroid: View {
    let photo: AlbumPhoto?
    var width: CGFloat
    var height: CGFloat
    var tilt: Double = 0
    var border: CGFloat = 5

    var body: some View {
        Group {
            if let photo, let image = cachedImage(photo.data, key: photo.id.uuidString) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Palette.fill
            }
        }
        .frame(width: width - border * 2, height: height - border * 2)
        .clipShape(RoundedRectangle(cornerRadius: max(4, Radius.tile - border), style: .continuous))
        .padding(border)
        .background {
            RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.13), radius: 12, y: 8)
        }
        .rotationEffect(.degrees(tilt))
    }
}

/// 动态里的配图：一张就大一点、微微歪着；几张就错开叠在一起
struct PolaroidStack: View {
    let photos: [AlbumPhoto]

    var body: some View {
        if photos.count == 1 {
            Polaroid(photo: photos[0], width: 236, height: 220, tilt: -1.5)
                .padding(.vertical, 6)
                .padding(.leading, 4)
        } else {
            ZStack(alignment: .topLeading) {
                ForEach(Array(photos.prefix(3).enumerated()), id: \.element.id) { i, p in
                    Polaroid(photo: p, width: 172, height: 184, tilt: [-3, 4, -1][i])
                        .offset(x: CGFloat(i) * 104, y: CGFloat(i % 2) * 22)
                }
            }
            .frame(height: 214, alignment: .topLeading)
            .padding(.vertical, 4)
            .padding(.leading, 4)
        }
    }
}

/// 发你自己的动态：写几句、选几张照片、挑个心情
struct MomentComposer: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(RelayClient.self) private var relay
    @State private var text = ""
    @State private var mood = ""
    @State private var items: [PhotosPickerItem] = []
    @State private var photos: [Data] = []
    @FocusState private var focused: Bool

    static let moods = ["开心", "想你", "平静", "有点累", "期待"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) {
                    TextField("这一刻的想法…", text: $text, axis: .vertical)
                        .font(.system(size: 16))
                        .lineLimit(4...12)
                        .focused($focused)
                        .padding(Space.card)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.tile + 2, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.tile + 2, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.tight) {
                            ForEach(Array(photos.enumerated()), id: \.offset) { i, data in
                                Group {
                                    if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill() } else { Palette.fill }
                                }
                                .frame(width: 76, height: 76)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button { withAnimation(Motion.spring) { _ = photos.remove(at: i) } } label: {
                                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                            .frame(width: 22, height: 22).background(.black.opacity(0.5), in: Circle())
                                    }
                                    .padding(4)
                                    .accessibilityLabel("移除")
                                }
                            }
                            if photos.count < 9 {
                                PhotosPicker(selection: $items, maxSelectionCount: 9 - photos.count, matching: .images) {
                                    Image(systemName: "plus").font(.system(size: 20)).foregroundStyle(Palette.inkSoft)
                                        .frame(width: 76, height: 76)
                                        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                                            .strokeBorder(Palette.faint, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                }
                                .accessibilityLabel("添加照片")
                            }
                        }
                    }
                    HStack(spacing: Space.tight) {
                        ForEach(Self.moods, id: \.self) { m in
                            Button { withAnimation(Motion.snappy) { mood = mood == m ? "" : m } } label: {
                                Text(LocalizedStringKey(m))
                                    .font(.system(size: Typo.label))
                                    .foregroundStyle(mood == m ? Palette.inkInverse : Palette.ink)
                                    .padding(.horizontal, 12)
                                    .frame(height: 32)
                                    .background(mood == m ? Palette.ink : Palette.card, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: mood == m ? 0 : 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(Space.page)
            }
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle("New moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发表") {
                        MomentsEngine.shared.publish(text: text, mood: mood, photos: photos, context: context, relay: relay)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(text.trimmed.isEmpty && photos.isEmpty)
                }
            }
        }
        .onAppear { focused = true }
        .onChange(of: items) { _, picked in
            guard !picked.isEmpty else { return }
            Task {
                for item in picked {
                    if let data = try? await item.loadTransferable(type: Data.self), let small = ImageUtil.downscale(data) {
                        withAnimation(Motion.spring) { photos.append(small) }
                    }
                }
                items = []
            }
        }
    }
}
