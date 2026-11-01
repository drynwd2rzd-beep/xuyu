import SwiftUI

/// 写想法：一段较长的文字，以便签卡片的样子发出
struct NoteComposer: View {
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            HStack {
                Button("取消") { dismiss() }.foregroundStyle(Palette.inkSoft)
                Spacer()
                Text("写想法").font(Typo.serif(18, .medium)).foregroundStyle(Palette.ink)
                Spacer()
                Button("发送") {
                    onSend(text.trimmed)
                    dismiss()
                }
                .fontWeight(.semibold)
                .foregroundStyle(Palette.ink)
                .disabled(text.trimmed.isEmpty)
            }
            TextEditor(text: $text)
                .font(Typo.serif(17))
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(Space.item)
                .card(radius: Radius.tile)
        }
        .padding(Space.page)
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }
}
