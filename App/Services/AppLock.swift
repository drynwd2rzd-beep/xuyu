import SwiftUI
import LocalAuthentication
import Observation

/// App 锁：打开 App、让 TA 操作电脑之前，用 Face ID（或手机密码）确认是你本人。
/// 锁屏画在单独的窗口里，盖住整个 App（LockWindowPresenter）
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    /// 锁住了：要 Face ID 才能看到 App
    var locked = UserDefaults.standard.bool(forKey: Prefs.appLock) && !DemoMode.isOn
    /// 离开 App 的那一刻先挡住：多任务切换器的截图里看不到聊天。不用 Face ID，回到前台就撤掉（审查 Z-025）
    private(set) var shielded = false
    /// 现在要不要盖住整个 App
    var covering: Bool { locked || shielded }

    @ObservationIgnored private var unlocking = false
    /// 正在弹 Face ID：这时 App 也会变成「不活跃」，不要因此挡住
    @ObservationIgnored private var authenticating = false
    /// 这次锁住以后还会不会自己弹 Face ID：你取消过一次，就停在锁屏等你点「解锁」（审查 Z-026）
    @ObservationIgnored private var autoPrompt = true
    @ObservationIgnored private var workConfirmedAt = Date.distantPast
    @ObservationIgnored private var activation: Task<Void, Never>?

    private init() {
        // 每次回到前台（包括刚打开）：锁着就自动弹一次 Face ID
        activation = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                await self?.unlock(auto: true)
            }
        }
    }

    var enabled: Bool { UserDefaults.standard.bool(forKey: Prefs.appLock) && !DemoMode.isOn }

    /// 切到后台时锁上，下次回来要先解锁；操作电脑的确认也一起失效
    func lockIfNeeded() {
        workConfirmedAt = .distantPast
        guard enabled else { return }
        locked = true
        autoPrompt = true
    }

    /// App 变得不活跃（上滑回主屏幕、打开多任务切换器）：开着 App 锁就先挡住
    func shieldIfNeeded() {
        guard enabled, !authenticating else { return }
        shielded = true
    }

    /// 回到前台：撤掉挡板（锁住的话锁屏还在）
    func unshield() {
        shielded = false
    }

    /// 现在发给会操作电脑的角色，要不要先确认（没开保护、或 5 分钟内确认过就不用）
    var needsWorkConfirm: Bool {
        UserDefaults.standard.bool(forKey: Prefs.workAuth) && !DemoMode.isOn && Date.now.timeIntervalSince(workConfirmedAt) >= 300
    }

    /// 让 TA 操作电脑前确认是你本人；确认过后 5 分钟内连着发不再问
    func confirmWork() async -> Bool {
        guard needsWorkConfirm else { return true }
        guard await prompt("让 TA 操作你的电脑") else { return false }
        workConfirmedAt = .now
        return true
    }

    /// 解锁。auto 是回到前台时自动弹的：你取消过一次以后就不再自动弹，等你点「解锁」
    func unlock(auto: Bool = false) async {
        // 在后台时弹不出 Face ID，等回到前台再解锁
        guard locked, !unlocking, UIApplication.shared.applicationState == .active else { return }
        guard !auto || autoPrompt else { return }
        unlocking = true
        defer { unlocking = false }
        if await prompt("解锁絮语") {
            locked = false
        } else {
            autoPrompt = false
        }
    }

    /// 弹 Face ID，弹窗期间记下来（不让它触发挡板）
    private func prompt(_ reason: String) async -> Bool {
        authenticating = true
        defer { authenticating = false }
        return await Self.authenticate(reason)
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
