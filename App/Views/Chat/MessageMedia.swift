import SwiftUI
import UIKit
import QuickLook

/// 聊天里的照片（照设计稿）：一张 4:5 的圆角照片，统一调色，不加白边和阴影；
/// 几张就左右滑着看，右上角「1/3」。点一下看大图
struct ImageStack: View {
    let attachments: [Attachment]
    let onOpen: (Int) -> Void
    @State private var top = 0

    var body: some View {
        let count = attachments.count
        TabView(selection: $top) {
            ForEach(Array(attachments.enumerated()), id: \.element.id) { index, a in
                card(a).tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(width: Self.width, height: Self.width * 5 / 4)
        .clipShape(.rounded(Radius.bubble))
        .overlay(alignment: .topTrailing) {
            if count > 1 {
                Text(verbatim: "\(top + 1)/\(count)")
                    .font(Typo.serif(Typo.label))
                    .monospacedDigit()
                    .foregroundStyle(Palette.onPhoto)
                    .padding(.horizontal, Space.tight)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(Space.tight)
                    .contentTransition(.numericText())
            }
        }
        .contentShape(.rounded(Radius.bubble))
        .onTapGesture { onOpen(top) }
        .sensoryFeedback(.selection, trigger: top)
        .accessibilityLabel(Text("\(count) 张照片"))
    }

    /// 照片的宽度（照设计稿 210 点）
    private static let width: CGFloat = 210

    private func card(_ a: Attachment) -> some View {
        Color.clear
            .overlay {
                if let image = cachedImage(a.data, key: a.id.uuidString) {
                    Image(uiImage: image).resizable().scaledToFill().graded()
                } else {
                    Palette.fill
                }
            }
            .clipped()
    }
}

struct NoteCard: View {
    let text: String
    let time: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Label("想法", systemImage: "pencil.line")
                .font(Typo.serif(13))
                .foregroundStyle(Palette.inkSoft)
            Text(text)
                .font(Typo.serif(16))
                .lineSpacing(5)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(time).font(TimedText.stampFont).foregroundStyle(TimedText.stampColor)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(Space.card)
        .frame(maxWidth: 260, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .fill(Palette.card)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.clay.opacity(0.5)).frame(height: 3)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: Radius.tile, topTrailingRadius: Radius.tile, style: .continuous))
        }

    }
}

struct FileCard: View {
    let name: String
    let size: Int
    let time: String
    /// 有文件内容时，点一下用系统预览打开（能保存到「文件」、分享给其他 App）
    var data: Data? = nil
    @State private var previewURL: URL?

    var body: some View {
        card
            .contentShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .onTapGesture { open() }
            .quickLookPreview($previewURL)
    }

    private func open() {
        guard let data else { return }
        // 每次打开放进自己的临时文件夹，名字再清理一遍：旧消息里的名字可能没清理过（FileName）
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        // 临时文件夹建不了、写不进去时，预览打开是空的；聊天里的文件本身不受影响
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(FileName.safe(name))
        try? data.write(to: url, options: .atomic)
        previewURL = url
    }

    private var card: some View {
        HStack(spacing: Space.item) {
            Image(systemName: "doc.text")
                .font(.system(size: 20))
                .foregroundStyle(Palette.ink)
                .frame(width: 42, height: 42)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 15)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + " · " + time)
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
            }
        }
        .padding(Space.item)
        .frame(maxWidth: 250, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))

    }
}
