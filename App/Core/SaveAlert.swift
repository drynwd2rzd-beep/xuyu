import SwiftUI
import SwiftData

/// 保存失败时的提示。以前保存出错会被悄悄吞掉（比如手机存储满了），界面看着正常、东西其实没存上；
/// 现在屏幕最上面会出现一句提示，几秒后自己收起，连着出错也只提示一次
@MainActor
@Observable
final class SaveAlert {
    static let shared = SaveAlert()

    private(set) var showing = false
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func report() {
        withAnimation(Motion.spring) { showing = true }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.spring) { self?.showing = false }
        }
    }
}

extension ModelContext {
    /// 保存改动；失败时提示出来，不再悄悄吞掉
    func persist() {
        do {
            try save()
        } catch {
            Task { @MainActor in SaveAlert.shared.report() }
        }
    }
}

/// 屏幕最上面那句「没能保存」：样子和聊天页里的小提示一样
struct SaveAlertToast: View {
    var body: some View {
        if SaveAlert.shared.showing {
            Text("没能保存刚才的改动，手机存储可能已满")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.onNoir)
                .padding(.horizontal, Space.card)
                .frame(height: 36)
                .background(Palette.noir, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
