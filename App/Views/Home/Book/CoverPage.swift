import SwiftUI
import SwiftData
import PhotosUI

/// 画册封面：铺满一屏的照片（你选的那张；没选就用 TA 最近一张照片），压着 TA 今天留给你的那句话。
/// 页眉是日期和天气，点日期打开月历去看别的日子；右上角的头像进设置。长按封面可以换照片
struct CoverPage: View {
    let total: Int
    let onCalendar: () -> Void
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var context
    @AppStorage(Prefs.whisperText) private var text = ""
    @AppStorage(Prefs.whisperAuthor) private var author = ""
    @AppStorage(Prefs.widgetPhotoStamp) private var photoStamp = 0.0
    @Query(sort: \Persona.createdAt) private var personas: [Persona]
    @Query(sort: \AlbumPhoto.createdAt, order: .reverse) private var album: [AlbumPhoto]
    @State private var picking = false
    @State private var item: PhotosPickerItem?
    @State private var cover: UIImage?
    @State private var failed = false
    /// 封面是不是你自己选的照片（是才有「不用这张照片」）
    @State private var mine = false
    /// 封面铺满一屏：按「屏幕高度 × 3 倍屏」解码（CONC-2）
    private static let coverPixel = 2600

    var body: some View {
        BookPage(folio: folio, number: 1, total: total, onDark: cover != nil, trailing: AnyView(settingsButton), onFolio: onCalendar) {
            if let cover {
                BookPhoto(image: cover)
            } else {
                // 还没有照片：那一页就是一片很淡的光
                LinearGradient(colors: [Palette.Mood.calm.t1, Palette.paper], startPoint: .top, endPoint: .bottom)
            }
        } content: {
            VStack(alignment: .leading, spacing: Space.page) {
                Text(text.isEmpty ? String(localized: "连上电脑后，Claude 每天会在这里留一句话给你。") : text)
                    .font(Typo.serif(Typo.Book.quote))
                    .lineSpacing(Typo.Book.quoteSpacing)
                    .tracking(Typo.tracking)
                    .foregroundStyle(cover != nil ? Palette.onPhoto : Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .reveal()
                Byline(parts: byline, onDark: cover != nil).reveal(1)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: openChat)
        }
        .contextMenu {
            Button { picking = true } label: { Label("换封面照片", systemImage: "photo") }
            if mine {
                Button(role: .destructive) { withAnimation(Motion.glide) { ImageFileStore.widgetPhoto.clear() } } label: {
                    Label("不用这张照片", systemImage: "xmark")
                }
            }
        }
        .photosPicker(isPresented: $picking, selection: $item, matching: .images)
        .onChange(of: item) { _, item in
            guard let item else { return }
            Task {
                // 读不出来就告诉你（ERR-2），选的照片原样留着
                if let data = try? await item.loadTransferable(type: Data.self), ImageFileStore.widgetPhoto.save(data) {
                    loadCover()
                } else {
                    failed = true
                }
                self.item = nil
            }
        }
        .alert("这张照片没读出来，换一张试试。", isPresented: $failed) { Button("好", role: .cancel) {} }
        .task(id: "\(photoStamp)-\(album.first?.id.uuidString ?? "")") { loadCover() }
    }

    /// 「11月2日 周一　大风 12°」
    private var folio: String {
        let date = Fmt.md.string(from: .now) + " " + Fmt.weekday.string(from: .now)
        return [date, Weather.summary].compactMap { $0 }.joined(separator: "　")
    }

    /// 「晚星 · 在一起第 251 天」
    private var byline: [String] {
        var parts: [String] = []
        if !author.isEmpty { parts.append(author) }
        if let start = personas.first?.createdAt {
            let days = (Calendar.current.dateComponents([.day], from: start.startOfDay, to: Date.now.startOfDay).day ?? 0) + 1
            parts.append(String(localized: "在一起第 \(days) 天"))
        }
        return parts
    }

    private var settingsButton: some View {
        Button { router.open(.settings) } label: { UserAvatar(size: AvatarSize.folio) }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel("设置")
    }

    /// 你选的照片优先；没有就用 TA 最近一张照片（解码在 cachedImage 里按显示尺寸做，CONC-2）
    private func loadCover() {
        mine = false
        if let picked = ImageFileStore.widgetPhoto.image {
            mine = true
            cover = picked
        } else if let photo = album.first {
            cover = cachedImage(photo.data, key: photo.id.uuidString, maxPixel: Self.coverPixel)
        } else {
            cover = nil
        }
    }

    /// 点那句话：去和写它的那位聊天
    private func openChat() {
        let who = personas.first { $0.name == author } ?? personas.first
        guard let who else { return }
        router.tab = .chats
        router.open(.chat(context.chat(for: who).id))
    }
}
