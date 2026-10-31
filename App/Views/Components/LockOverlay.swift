import SwiftUI
import UIKit

/// 把锁屏放进一个单独的窗口，压在整个 App 上面：sheet、全屏页（看图、通话、一起读）、横幅都盖得住。
/// 以前锁屏只盖在首页那一层上，从首页弹出来的页面在它上面，锁住了照样能看能点（审查 Z-001、规范 NAV-5）
struct LockWindowPresenter: UIViewRepresentable {
    let lock: AppLock
    /// 现在要不要盖住（锁住了，或者离开 App 时先挡一下）
    let covering: Bool
    /// 跟着 App 里选的浅色 / 深色：单独的窗口不会自己继承
    let style: UIUserInterfaceStyle

    func makeCoordinator() -> Coordinator { Coordinator(lock: lock) }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.onWindow = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        context.coordinator.update(covering: covering, style: style)
    }

    /// 放在首页背后的空视图：只用来找到 App 的主窗口
    final class AnchorView: UIView {
        var onWindow: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    @MainActor
    final class Coordinator {
        private let lock: AppLock
        private weak var mainWindow: UIWindow?
        private var lockWindow: UIWindow?
        private var covering = false
        private var style = UIUserInterfaceStyle.unspecified

        init(lock: AppLock) { self.lock = lock }

        func attach(to window: UIWindow) {
            guard mainWindow == nil, let scene = window.windowScene else { return }
            mainWindow = window
            let host = UIHostingController(rootView: LockScreen(lock: lock))
            host.view.backgroundColor = .clear
            let lockWindow = UIWindow(windowScene: scene)
            // 比系统提示框还高一层
            lockWindow.windowLevel = .alert + 1
            lockWindow.rootViewController = host
            lockWindow.isHidden = true
            self.lockWindow = lockWindow
            apply(animated: false)
        }

        func update(covering: Bool, style: UIUserInterfaceStyle) {
            self.style = style
            lockWindow?.overrideUserInterfaceStyle = style
            guard covering != self.covering else { return }
            self.covering = covering
            apply(animated: !covering)
        }

        /// 盖上时立刻盖（离开 App 的那一刻来不及做动画）；解锁时淡出
        private func apply(animated: Bool) {
            guard let lockWindow else { return }
            lockWindow.overrideUserInterfaceStyle = style
            // 锁住时后面的内容读屏也读不到（审查 Z-145）
            mainWindow?.accessibilityElementsHidden = covering
            if covering {
                // 键盘在更高的窗口里：不收起的话会露在锁屏上面，还能接着打字
                mainWindow?.endEditing(true)
                lockWindow.alpha = 1
                lockWindow.isHidden = false
                UIAccessibility.post(notification: .screenChanged, argument: lockWindow)
            } else if animated, !lockWindow.isHidden {
                UIView.animate(Motion.spring) {
                    lockWindow.alpha = 0
                } completion: { [weak self] in
                    guard let self, !self.covering else { return }
                    lockWindow.isHidden = true
                    lockWindow.alpha = 1
                }
            } else {
                lockWindow.isHidden = true
            }
        }
    }
}

/// 锁屏：完全不透明的纸色，看不到后面任何内容（审查 Z-425）。
/// 只是离开 App 时挡一下（没锁）的时候不显示「解锁」
struct LockScreen: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            VStack(spacing: Space.section) {
                Image(systemName: "lock")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 64, height: 64)
                    .background(Palette.card, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 0.5))
                    .accessibilityHidden(true)
                Text("絮语").font(Typo.serif(22, .medium)).foregroundStyle(Palette.ink)
                if lock.locked {
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
        }
        .accessibilityAddTraits(.isModal)
    }
}
