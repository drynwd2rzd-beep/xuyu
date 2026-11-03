import SwiftUI

/// 画册最后一页：TA 最近一条带照片的动态，照片铺满一屏，压着 TA 写的那句话和谁喜欢了。点一下去动态页
struct PostPage: View {
    let moment: Moment
    let photo: AlbumPhoto
    let names: [UUID: String]
    let number: Int
    let total: Int
    @Environment(Router.self) private var router
    @State private var image: UIImage?
    /// 铺满一屏：按「屏幕高度 × 3 倍屏」解码（CONC-2）
    private static let pixel = 2600

    var body: some View {
        let name = moment.personaID.flatMap { names[$0] } ?? ""
        PhotobookPage(folio: String(localized: "\(name)的动态　\(Fmt.bubble.string(from: moment.createdAt))"),
                 number: number, total: total, onDark: true) {
            if let image { PhotobookPhoto(image: image) } else { Palette.listenNight }
        } content: {
            VStack(alignment: .leading, spacing: Space.page) {
                if !moment.text.trimmed.isEmpty {
                    Text(verbatim: moment.text.trimmed)
                        .font(Typo.serif(Typo.Book.post))
                        .lineSpacing(Typo.Book.quoteSpacing)
                        .tracking(Typo.tracking)
                        .foregroundStyle(Palette.onPhoto)
                        .lineLimit(Self.maxLines)
                        .reveal()
                }
                Byline(parts: byline(name)).reveal(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { router.tab = .moments }
        }
        .task(id: photo.id) { image = cachedImage(photo.data, key: photo.id.uuidString, maxPixel: Self.pixel) }
    }

    private static let maxLines = 6

    /// 「晚星 · 阿澈 和 小雨 喜欢」
    private func byline(_ name: String) -> [String] {
        let likers = moment.likedBy.compactMap { names[$0] } + (moment.likedByMe ? [String(localized: "你")] : [])
        guard !likers.isEmpty else { return [name] }
        return [name, String(localized: "\(likers.joined(separator: String(localized: " 和 "))) 喜欢")]
    }
}
