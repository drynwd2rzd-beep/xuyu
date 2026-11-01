import SwiftUI
import SwiftData

/// 聊天页的底部：多选时是「取消 / 已选几条 / 删除」的条，平时是输入栏；还有顶上一闪而过的轻提示
extension ChatView {
    // MARK: - 底部

    @ViewBuilder
    var bottomBar: some View {
        if selecting {
            selectionBar
        } else {
            Composer(draft: $draft, panel: $panel, quote: $quoting, panelHeight: panelHeight, convo: convo, members: members,
                     onSend: send, onExpand: { pinBottom += 1 }, inputFocused: $inputFocused)
        }
    }

    /// 多选时的底栏：取消、已选几条、删除
    private var selectionBar: some View {
        HStack {
            Button("取消") {
                withAnimation(Motion.spring) {
                    selecting = false
                    picked = []
                }
            }
            .font(.system(size: 15))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Space.card)
            Spacer()
            Text("已选 \(picked.count) 条").font(.system(size: 14)).foregroundStyle(Palette.ink2)
            Spacer()
            Button {
                deleteMessages(picked)
                withAnimation(Motion.spring) {
                    selecting = false
                    picked = []
                }
            } label: {
                Text("删除")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: Space.control)
                    .background(picked.isEmpty ? Palette.danger.opacity(0.4) : Palette.danger, in: Capsule())
            }
            .disabled(picked.isEmpty)
        }
        .padding(Space.tight)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
        .padding(.horizontal, Space.page)
        .padding(.bottom, Space.tight)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// 发出去：带上正在引用的那句；会操作电脑的角色先确认是你本人
    private func send(_ text: String, kind: MessageKind, attachments: [OutgoingAttachment]) {
        let quote = quoting ?? ""
        let quoteID = quoting == nil ? nil : quotingID
        withAnimation(Motion.spring) { quoting = nil }
        quotingID = nil
        let deliver = { engine.send(text, kind: kind, attachments: attachments, quote: quote, quoteID: quoteID, in: convo, members: members, context: context) }
        guard members.contains(where: \.canWork), AppLock.shared.needsWorkConfirm else { return deliver() }
        // 会操作电脑的角色：开了保护就先确认是你本人；没通过就把话放回输入框
        Task {
            if await AppLock.shared.confirmWork() {
                deliver()
            } else {
                if kind == .text { draft = text }
                flash("没有通过验证")
            }
        }
    }

    // MARK: - 轻提示

    /// 顶上一闪而过的一句话（已复制、已加入待办……）
    @ViewBuilder
    var toastBanner: some View {
        if let toast {
            Text(LocalizedStringKey(toast))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.onNoir)
                .padding(.horizontal, Space.card)
                .frame(height: 36)
                .background(Palette.noir, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// 轻提示出现 1.6 秒后自己收起
    func flash(_ text: String) {
        withAnimation(Motion.spring) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Motion.spring) { toast = nil }
        }
    }
}
