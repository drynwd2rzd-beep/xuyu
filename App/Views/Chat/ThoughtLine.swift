import SwiftUI

/// 气泡上方那一行心声：收着时只露一行，点一下展开全部（左边一条细线，和「思考过程」一样）
struct ThoughtLine: View {
    let text: String
    @State private var open = false
    private var font: ThoughtFont { ThoughtFont.shared }

    var body: some View {
        Button { withAnimation(Motion.spring) { open.toggle() } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(text)
                    .font(font.font(14.5))
                    .lineSpacing(3)
                    .foregroundStyle(Palette.inkSoft)
                    .lineLimit(open ? nil : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.faint)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) { Rectangle().fill(Palette.hairline).frame(width: 2) }
            .padding(.leading, 2)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("心里想：\(text)"))
        .onAppear { font.prepare() }
    }
}
