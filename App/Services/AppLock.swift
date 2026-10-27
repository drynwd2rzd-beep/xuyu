import SwiftUI
import LocalAuthentication
import Observation

/// App 锁：打开 App、让 TA 操作电脑之前，用 Face ID（或手机密码）确认是你本人
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    var locked = UserDefaults.standard.bool(forKey: Prefs.appLock) && !DemoMode.isOn
    @ObservationIgnored private var unlocking = false
    @ObservationIgnored private var workConfirmedAt = Date.distantPast

    var enabled: Bool { UserDefaults.standard.bool(forKey: Prefs.appLock) && !DemoMode.isOn }

    /// 切到后台时锁上，下次回来要先解锁；操作电脑的确认也一起失效
    func lockIfNeeded() {
        workConfirmedAt = .distantPast
        if enabled { locked = true }
    }

    /// 现在发给会操作电脑的角色，要不要先确认（没开保护、或 5 分钟内确认过就不用）
    var needsWorkConfirm: Bool {
        UserDefaults.standard.bool(forKey: Prefs.workAuth) && !DemoMode.isOn && Date.now.timeIntervalSince(workConfirmedAt) >= 300
    }

    /// 让 TA 操作电脑前确认是你本人；确认过后 5 分钟内连着发不再问
    func confirmWork() async -> Bool {
        guard needsWorkConfirm else { return true }
        guard await Self.authenticate("让 TA 操作你的电脑") else { return false }
        workConfirmedAt = .now
        return true
    }

    func unlock() async {
        // 在后台时弹不出 Face ID，等回到前台再解锁
        guard locked, !unlocking, UIApplication.shared.applicationState == .active else { return }
        unlocking = true
        defer { unlocking = false }
        if await Self.authenticate("解锁絮语") {
            withAnimation(Motion.spring) { locked = false }
        }
    }

    /// 用 Face ID 确认；手机没设密码时没法验证，直接放行
    static func authenticate(_ reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// 锁住时盖在最上面：看不到任何聊天内容
struct LockScreen: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Palette.paper.opacity(0.75).ignoresSafeArea()
            VStack(spacing: Space.section) {
                Image(systemName: "lock")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 64, height: 64)
                    .background(Palette.card, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 0.5))
                Text("絮语").font(Typo.serif(22, .medium)).foregroundStyle(Palette.ink)
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Text("解锁")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.inkInverse)
                        .padding(.horizontal, 28)
                        .frame(height: 44)
                        .background(Palette.ink, in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .transition(.opacity)
        .task { await lock.unlock() }
    }
}
