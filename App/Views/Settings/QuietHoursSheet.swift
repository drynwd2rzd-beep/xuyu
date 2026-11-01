import SwiftUI

// MARK: - 免打扰

/// 设置 › 通知 › 免打扰：选开始和结束的钟点（整点），这段时间里角色不会主动找你
struct QuietHoursSheet: View {
    @Binding var start: Int
    @Binding var end: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            HStack {
                Text("免打扰").font(Typo.serif(20, .medium)).foregroundStyle(Palette.ink)
                Spacer()
                Button("完成") { dismiss() }.fontWeight(.semibold).foregroundStyle(Palette.ink)
            }
            HStack {
                picker("开始", $start)
                Text("–").foregroundStyle(Palette.inkSoft)
                picker("结束", $end)
            }
            .padding(Space.card)
            .card()
            Text("这段时间里，角色不会主动给你发消息。").font(.system(size: 13)).foregroundStyle(Palette.inkSoft).padding(.leading, 6)
        }
        .padding(Space.page)
    }

    /// 一个钟点滚轮：上面一行小字写是开始还是结束
    private func picker(_ label: String, _ value: Binding<Int>) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
            Picker(label, selection: value) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(height: 110)
        }
        .frame(maxWidth: .infinity)
    }
}
