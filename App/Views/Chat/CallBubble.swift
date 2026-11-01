import SwiftUI

/// 聊天里的「通话时长」气泡，点开看通话内容和「再打一次」
struct CallBubble: View {
    let message: Message
    let isUser: Bool
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: Space.tight) {
                Image(systemName: "phone").font(.system(size: 14))
                Text("通话时长 \(message.content)").font(.system(size: Typo.body))
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isUser ? Palette.fill : Palette.card, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $open) {
            CallLogSheet(message: message)
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
    }
}

/// 一通电话的全部内容（中文和韩语），底下可以再打一次
struct CallLogSheet: View {
    let message: Message
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let lines = CallLogs.shared.lines(message.id)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Voice call").font(Typo.display(26)).foregroundStyle(Palette.ink)
                    Spacer()
                    Text("\(message.content) · \(Fmt.hm.string(from: message.createdAt))").font(Typo.serif(14).italic()).foregroundStyle(Palette.inkSoft)
                }
                .padding(.top, 24)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        if index > 0 { Hairline() }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.mine ? "you" : (message.conversation?.title.isEmpty == false ? message.conversation!.title : "TA"))
                                .font(Typo.serif(12.5).italic()).foregroundStyle(Palette.inkSoft)
                            Text(line.zh).font(.system(size: 15)).foregroundStyle(Palette.ink)
                            if !line.ko.isEmpty { Text(line.ko).font(.system(size: 13)).foregroundStyle(Palette.inkSoft) }
                        }
                        .padding(.horizontal, Space.card)
                        .padding(.vertical, 11)
                    }
                    if lines.isEmpty {
                        Text("这通电话没有留下文字。").font(.system(size: 14)).foregroundStyle(Palette.inkSoft).padding(Space.card)
                    }
                }
                .card()
                Button {
                    dismiss()
                    if let id = message.conversation?.id { NotificationCenter.default.post(name: CallLogs.callAgain, object: id) }
                } label: {
                    Label("再打一次", systemImage: "phone").font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Palette.inkInverse)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(Palette.ink, in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, 30)
        }
    }
}
