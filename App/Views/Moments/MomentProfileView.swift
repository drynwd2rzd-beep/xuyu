import SwiftUI
import SwiftData
import PhotosUI

/// TA 的主页（点聊天顶部的头像进来）：头像、名字、一句签名，相册里的照片，再按日子排的动态
struct MomentProfileView: View {
    let persona: Persona
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(Router.self) private var router
    @Query(sort: \Moment.createdAt, order: .reverse) private var moments: [Moment]
    @Query(sort: \AlbumPhoto.createdAt) private var photos: [AlbumPhoto]
    @State private var showAlbum = false

    var body: some View {
        let album = photos.filter { $0.personaID == persona.id }
        let theirs = moments.filter { $0.personaID == persona.id && $0.createdAt <= .now }
        let pictures = Dictionary(album.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("返回")
                    Spacer()
                    Button { router.open(.persona(persona.id)) } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("编辑角色")
                }
                .padding(.horizontal, Space.tight)

                profile(albumCount: album.count, momentCount: theirs.count)

                if !album.isEmpty {
                    DayDivider(label: "From the album")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.section) {
                            ForEach(Array(album.reversed().enumerated()), id: \.element.id) { i, p in
                                Polaroid(photo: p, width: 92, height: 104, tilt: [-3, 2, -1.5, 3, -2][i % 5], border: 4)
                            }
                        }
                        .padding(.horizontal, Space.page + 6)
                        .padding(.vertical, Space.section)
                    }
                }

                DayDivider(label: "Moments")
                if theirs.isEmpty {
                    Text("还没有发过动态。")
                        .font(Typo.serif(15).italic())
                        .foregroundStyle(Palette.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Space.page + 6)
                }
                timeline(theirs, pictures: pictures)
            }
            .padding(.bottom, 60)
        }
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

    private func profile(albumCount: Int, momentCount: Int) -> some View {
        let signature = persona.bio.trimmed.components(separatedBy: .newlines).first?.trimmed ?? ""
        return VStack(spacing: 4) {
            AvatarView(persona: persona, size: 84)
                .padding(5)
                .overlay(Circle().strokeBorder(Palette.ink, lineWidth: 1.5))
            Text(persona.name)
                .font(Typo.display(34))
                .tracking(-0.5)
                .foregroundStyle(Palette.ink)
                .padding(.top, Space.item)
            if !signature.isEmpty {
                Text("“\(signature)”")
                    .font(Typo.serif(16).italic())
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            Text(verbatim: "\(momentCount) \(momentCount == 1 ? "moment" : "moments") · \(albumCount) \(albumCount == 1 ? "photo" : "photos")")
                .font(Typo.serif(13))
                .foregroundStyle(Palette.faint)
                .padding(.top, 4)
            HStack(spacing: 10) {
                Button(action: openChat) {
                    Text("发消息")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.inkInverse)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Palette.ink, in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
                Button { showAlbum = true } label: {
                    Text("相册")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Palette.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(.top, Space.section)
        }
        .padding(.horizontal, Space.page + 6)
    }

    /// 按日子排：左边是日期，右边是这条动态，中间一条细线串起来
    private func timeline(_ items: [Moment], pictures: [UUID: AlbumPhoto]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, m in
                Button { router.open(.moments) } label: {
                    HStack(alignment: .top, spacing: Space.section) {
                        VStack(spacing: 2) {
                            Text(Self.dayNumber.string(from: m.createdAt)).font(Typo.serif(26)).foregroundStyle(Palette.ink)
                            Text(Fmt.enMonthShort.string(from: m.createdAt)).font(Typo.serif(12)).foregroundStyle(Palette.faint)
                        }
                        .frame(width: 52)
                        .padding(.vertical, 4)
                        .background(Palette.paper)
                        VStack(alignment: .leading, spacing: Space.tight) {
                            if m.text.count <= 16 {
                                Text(m.text).font(Typo.serif(19)).foregroundStyle(Palette.ink)
                            } else {
                                Text(m.text).font(.system(size: 15)).lineSpacing(5).foregroundStyle(Palette.ink).lineLimit(4)
                            }
                            if let first = m.photoIDs.first.flatMap({ pictures[$0] }) {
                                Polaroid(photo: first, width: 112, height: 96, tilt: i % 2 == 0 ? -2 : 2, border: 4)
                                    .padding(.vertical, 4)
                            }
                            Text(meta(m)).font(.system(size: 12)).foregroundStyle(Palette.faint)
                        }
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(alignment: .topLeading) {
            Rectangle().fill(Palette.hairline).frame(width: 0.5).padding(.leading, 26).padding(.vertical, 18)
        }
        .padding(.horizontal, Space.page + 6)
        .padding(.top, 4)
    }

    private func meta(_ m: Moment) -> String {
        var parts = [Fmt.hm.string(from: m.createdAt)]
        let likes = m.likedBy.count + (m.likedByMe ? 1 : 0)
        let comments = m.visibleComments().count
        if likes > 0 { parts.append(String(localized: "\(likes) 人喜欢")) }
        if comments > 0 { parts.append(String(localized: "\(comments) 条评论")) }
        return parts.joined(separator: " · ")
    }

    private func openChat() {
        let convo = context.chat(for: persona)
        // 从聊天里点头像进来的：回去就是
        if router.chat == convo.id { dismiss() } else { router.open(.chat(convo.id)) }
    }

    static let dayNumber: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f
    }()
}

/// 相册：网格排着，点右上角的小叉移除，最后一格添加（一次能选好几张）
struct AlbumGrid: View {
    let personaID: UUID
    @Environment(\.modelContext) private var context
    @Query(sort: \AlbumPhoto.createdAt) private var photos: [AlbumPhoto]
    @State private var items: [PhotosPickerItem] = []

    var body: some View {
        let mine = photos.filter { $0.personaID == personaID }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.tight), count: 3), spacing: Space.tight) {
            ForEach(mine) { p in
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image = cachedImage(p.data, key: p.id.uuidString) { Image(uiImage: image).resizable().scaledToFill() }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            withAnimation(Motion.spring) { context.delete(p) }
                            try? context.save()
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 24, height: 24).background(.black.opacity(0.5), in: Circle())
                        }
                        .padding(5)
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
        .onChange(of: items) { _, picked in
            guard !picked.isEmpty else { return }
            Task {
                for item in picked {
                    if let data = try? await item.loadTransferable(type: Data.self), let small = ImageUtil.downscale(data) {
                        withAnimation(Motion.spring) { context.insert(AlbumPhoto(personaID: personaID, data: small)) }
                    }
                }
                try? context.save()
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
                        .font(Typo.serif(12.5).italic())
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
