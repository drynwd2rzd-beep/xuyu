import SwiftUI
import SwiftData
import PhotosUI

/// TA 的主页（点聊天顶部的头像、动态里的头像进来），照 X：最上面一条横幅照片（TA 相册里最新的一张），
/// 头像压在横幅下沿，右边是「发消息」「相册」；下面名字、一句签名、几条动态几张照片，再往下是 TA 的动态。
/// 往上滑横幅跟着变糊，往下拉横幅被拉大
struct MomentProfileView: View {
    let persona: Persona
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(Router.self) private var router
    @Query(sort: \Moment.createdAt, order: .reverse) private var moments: [Moment]
    @Query(sort: \AlbumPhoto.createdAt) private var photos: [AlbumPhoto]
    @Query private var personas: [Persona]
    @State private var showAlbum = false
    @State private var pull: CGFloat = 0
    private static let banner: CGFloat = 170

    var body: some View {
        let album = photos.filter { $0.personaID == persona.id }
        let theirs = moments.filter { $0.personaID == persona.id && $0.createdAt <= .now }
        let pictures = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let people = Dictionary(personas.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                banner(album.last)
                profile(albumCount: album.count, momentCount: theirs.count)
                if theirs.isEmpty {
                    Text("还没有发过动态。")
                        .font(Typo.serif(Typo.body))
                        .foregroundStyle(Palette.inkSoft)
                        .padding(.horizontal, Space.card)
                        .padding(.top, Space.group)
                }
                LazyVStack(spacing: 0) {
                    ForEach(theirs) { m in
                        PostView(moment: m, people: people, pictures: pictures, now: .now,
                                 onOpen: { comment in router.open(.moment(m.id, comment: comment)) },
                                 onProfile: { _ in })
                    }
                }
                .padding(.top, Space.group)
            }
            .padding(.bottom, Space.bookBottom)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in pull = y }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .top) { topButtons }
        .background(Palette.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showAlbum) {
            NavigationStack {
                ScrollView {
                    AlbumGrid(personaID: persona.id).padding(Space.page)
                }
                .background(Palette.paper.ignoresSafeArea())
                .navigationTitle(Text("\(persona.name) 的相册"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { showAlbum = false }.fontWeight(.semibold) }
                }
            }
            .presentationCornerRadius(Radius.sheet)
            .presentationBackground(Palette.paper)
        }
    }

    // MARK: - 横幅

    /// 横幅：往下拉（pull < 0）时被拉高，往上滑时变糊；没有照片就是 TA 心情色的一片光
    private func banner(_ photo: AlbumPhoto?) -> some View {
        let stretch = max(0, -pull)
        let blur = min(Self.maxBlur, max(0, pull) / Self.blurRate)
        return ZStack {
            if let photo {
                PhotoFill(photo: photo)
            } else {
                LinearGradient(colors: [Palette.Mood.calm.m2, Palette.Mood.tender.m3], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(height: Self.banner + stretch)
        .blur(radius: Motion.reduced ? 0 : blur)
        .clipped()
        .offset(y: -stretch)
        .padding(.bottom, -stretch)
        .accessibilityHidden(true)
    }

    private static let maxBlur: CGFloat = 12
    private static let blurRate: CGFloat = 10

    /// 压在横幅上的返回、编辑角色：白字，底下一小圈磨砂
    private var topButtons: some View {
        HStack {
            round("chevron.left", "返回") { dismiss() }
            Spacer()
            round("slider.horizontal.3", "编辑角色") { router.open(.persona(persona.id)) }
        }
        .padding(.horizontal, Space.item)
    }

    private func round(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Icon.plus, weight: .semibold))
                .foregroundStyle(Palette.onPhoto)
                .frame(width: Space.field, height: Space.field)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel(LocalizedStringKey(label))
    }

    // MARK: - 名字一栏

    private func profile(albumCount: Int, momentCount: Int) -> some View {
        let signature = persona.bio.trimmed.components(separatedBy: .newlines).first?.trimmed ?? ""
        return VStack(alignment: .leading, spacing: Space.tight) {
            HStack(alignment: .bottom) {
                AvatarView(persona: persona, size: AvatarSize.profile)
                    .padding(Space.tiny)
                    .background(Palette.paper, in: Circle())
                    .padding(.top, -AvatarSize.profileOverlap)
                Spacer()
                pill("发消息", filled: true, action: openChat)
                pill("相册", filled: false) { showAlbum = true }
            }
            Text(verbatim: persona.name)
                .font(.system(size: Typo.heading, weight: .medium))
                .tracking(Typo.tracking)
                .foregroundStyle(Palette.ink)
                .padding(.top, Space.tight)
            if !signature.isEmpty {
                Text(verbatim: signature)
                    .font(Typo.serif(Typo.body))
                    .lineSpacing(Space.tiny)
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(3)
            }
            HStack(spacing: Space.page) {
                count(momentCount, "动态")
                count(albumCount, "照片")
            }
            .padding(.top, Space.tiny)
        }
        .padding(.horizontal, Space.card)
    }

    private func count(_ n: Int, _ label: String) -> some View {
        HStack(spacing: Space.tiny) {
            Text(verbatim: "\(n)").font(.system(size: Typo.label, weight: .medium)).foregroundStyle(Palette.ink)
            Text(LocalizedStringKey(label)).font(.system(size: Typo.label)).foregroundStyle(Palette.inkSoft)
        }
    }

    private func pill(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(title))
                .font(.system(size: Typo.label, weight: .medium))
                .tracking(Typo.tracking)
                .foregroundStyle(filled ? Palette.inkInverse : Palette.ink)
                .padding(.horizontal, Space.card)
                .frame(height: Space.field)
                .background(filled ? Palette.ink : Palette.card, in: Capsule())
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func openChat() {
        let convo = context.chat(for: persona)
        // 从聊天里点头像进来的：回去就是
        if router.chat == convo.id { dismiss() } else { router.open(.chat(convo.id)) }
    }
}

/// 相册：网格排着，点右上角的小叉移除，最后一格添加（一次能选好几张）
struct AlbumGrid: View {
    let personaID: UUID
    @Environment(\.modelContext) private var context
    @Query(sort: \AlbumPhoto.createdAt) private var photos: [AlbumPhoto]
    @State private var items: [PhotosPickerItem] = []
    /// 要移除的那张：先问一句（以前点中小叉就直接没了）
    @State private var removing: AlbumPhoto?

    var body: some View {
        let mine = photos.filter { $0.personaID == personaID }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.tight), count: 3), spacing: Space.tight) {
            ForEach(mine) { p in
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image = cachedImage(p.data, key: p.id.uuidString) { Image(uiImage: image).resizable().scaledToFill().graded() }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Button { removing = p } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 24, height: 24).background(.black.opacity(0.5), in: Circle())
                                // 看起来还是那个小叉，能点的范围是 44×44
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("移除这张")
                    }
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            PhotosPicker(selection: $items, maxSelectionCount: 20, matching: .images) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { Image(systemName: "plus").font(.system(size: 20)).foregroundStyle(Palette.inkSoft) }
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                        .strokeBorder(Palette.faint, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            .accessibilityLabel("添加照片")
        }
        .confirmationDialog("从相册移除这张照片？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { p in
            Button("移除", role: .destructive) {
                withAnimation(Motion.spring) { context.delete(p) }
                context.persist()
            }
        }
        .onChange(of: items) { _, picked in
            guard !picked.isEmpty else { return }
            Task {
                for item in picked {
                    if let data = try? await item.loadTransferable(type: Data.self), let small = ImageUtil.downscale(data) {
                        withAnimation(Motion.spring) { context.insert(AlbumPhoto(personaID: personaID, data: small)) }
                    }
                }
                context.persist()
                items = []
            }
        }
    }
}

/// 聊天里 TA 提起自己的动态：消息上面一张小卡片，点一下去看
struct MomentQuoteCard: View {
    let moment: Moment
    let onOpen: () -> Void
    @Environment(\.modelContext) private var context

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Space.section) {
                if let photo = moment.photoIDs.first.flatMap({ context.photo($0) }) {
                    Polaroid(photo: photo, width: 58, height: 66, tilt: -4, border: 3)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("moment · \(Fmt.hm.string(from: moment.createdAt))")
                        .font(Typo.serif(Typo.secondary).italic())
                        .foregroundStyle(Palette.inkSoft)
                    Text("“\(moment.text)”")
                        .font(Typo.serif(15))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.item)
            .frame(maxWidth: 260, alignment: .leading)
            .background(Palette.botBubble.opacity(0.88), in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous).strokeBorder(Palette.hairline.opacity(0.7), lineWidth: 0.5))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

/// 消息上附的动态卡片：按编号找那条动态（删了就不显示）
struct MomentRef: View {
    let id: UUID
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router

    var body: some View {
        let target = id
        if let moment = try? context.fetch(FetchDescriptor<Moment>(predicate: #Predicate { $0.id == target })).first {
            MomentQuoteCard(moment: moment) { router.open(.moments) }
        }
    }
}
