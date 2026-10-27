import SwiftUI
import SwiftData
import UIKit
import PhotosUI

struct SelectableTextItem: Identifiable {
    let id = UUID()
    let text: String
}

/// 选择文字：把一条消息放大显示，可以随意拖动框选其中一部分来复制
struct SelectableTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            HStack {
                Text("选择文字").font(Typo.serif(18, .medium)).foregroundStyle(Palette.ink)
                Spacer()
                Button("完成") { dismiss() }.fontWeight(.semibold).foregroundStyle(Palette.ink)
            }
            SelectableTextView(text: text)
                .padding(Space.item)
                .card(radius: Radius.tile)
        }
        .padding(Space.page)
    }
}

struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .systemFont(ofSize: 17)
        view.textColor = UIColor(Palette.ink)
        view.text = text
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
