import SwiftUI
import UIKit
import QuickLook

/// 多张照片：叠成一摞，左右滑动切换
struct ImageStack: View {
    let attachments: [Attachment]
    let onOpen: (Int) -> Void
    @State private var top = 0
    @State private var drag: CGFloat = 0

    private let side: CGFloat = 188

    var body: some View {
        let count = attachments.count
        // 拖动进度：下面那张会随之慢慢升上来
        let progress = min(abs(drag) / 150, 1)
        ZStack {
            ForEach(Array(attachments.enumerated()), id: \.element.id) { index, a in
                let pos = (index - top + count) % count
                if pos < 3 || pos == count - 1 {
                    let layer = pos == count - 1 && count > 3 ? 2 : pos
                    card(a)
                        .scaleEffect(layer == 0 ? 1 - progress * 0.04 : (layer == 1 ? 0.97 + progress * 0.03 : 0.95))
                        .rotationEffect(.degrees(layer == 0 ? Double(drag / 24)
                                                 : (layer == 1 ? 5 * Double(1 - progress) : -5)))
                        .offset(x: layer == 0 ? drag : (layer == 1 ? 10 * (1 - progress) : -9),
                                y: layer == 0 ? 0 : (layer == 1 ? -9 * (1 - progress) : -12))
                        .zIndex(Double(3 - layer))
                }
            }
            if count > 1 {
                Text("\(top + 1) / \(count)")
                    .font(.system(size: Typo.caption, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: Capsule())
                    .frame(width: side, height: side, alignment: .topTrailing)
                    .padding(10)
                    .frame(width: side, height: side, alignment: .topTrailing)
                    .zIndex(9)
                    .contentTransition(.numericText())
            }
        }
        .frame(width: side, height: side)
        .padding(.top, count > 1 ? 12 : 0)
        .padding(.trailing, count > 1 ? 10 : 0)
        .contentShape(Rectangle())
        .onTapGesture { onOpen(top) }
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard count > 1, abs(value.translation.width) > abs(value.translation.height) else { return }
                    drag = value.translation.width
                }
                .onEnded { value in
                    guard count > 1 else { return }
                    let dx = value.translation.width
                    let flick = abs(value.predictedEndTranslation.width) > 180
                    if abs(dx) > 50 || flick {
                        // 同一个弹簧动画里：最上面那张顺着方向塞到最底下，下一张升上来
                        withAnimation(Motion.settle) {
                            top = dx < 0 ? (top + 1) % count : (top - 1 + count) % count
                            drag = 0
                        }
                    } else {
                        withAnimation(Motion.settle) { drag = 0 }
                    }
                }
        )
        .sensoryFeedback(.selection, trigger: top)
        .accessibilityLabel("\(count) 张照片")
    }

    private func card(_ a: Attachment) -> some View {
        Group {
            if let image = cachedImage(a.data, key: a.id.uuidString) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Palette.fill
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous).strokeBorder(.white, lineWidth: 3))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
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
                .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.clay.opacity(0.5)).frame(height: 3)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: Radius.tile, topTrailingRadius: Radius.tile, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name.isEmpty ? "文件" : name)
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
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }
}
