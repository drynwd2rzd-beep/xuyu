import SwiftUI
import SwiftData
import UIKit

/// 云端录屏用的动画剧本（`-demo YES -demoScreen motion`）：照片背景下，
/// 点进聊天 → 你发一句 → TA 打字再回 → 侧滑一半松手弹回 → 侧滑返回 → 再点进去 → 点返回散开。
/// 录下来逐帧看：有没有黑边、跳动、气泡突然冒出来
@MainActor
enum DemoMotion {
    static func run(router: Router, context: ModelContext, engine: ChatEngine) {
        useWallpaper()
        let all = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        guard let convo = all.filter({ !$0.isGroup }).max(by: { ($0.messages?.count ?? 0) < ($1.messages?.count ?? 0) }),
              let persona = convo.memberIDs.first.flatMap({ context.persona($0) }) else { return }
        let screen = UIScreen.main.bounds
        // 聊天列表第一行大概的位置
        let row = CGRect(x: 20, y: 236, width: screen.width - 40, height: 76)
        Task {
            await pause(2.5)
            router.open(.chat(convo.id), from: row)
            await pause(2)
            let mine = Message(role: .user, content: "在干嘛")
            withAnimation(Motion.bubble) {
                convo.add(mine, context: context)
            }
            await pause(1.2)
            await engine.demoReply("刚在刷手机，看到一个小狗偷吃被抓包的视频，嘴里还叼着证据。", as: persona, in: convo, context: context)
            // 连着说第二句：和真回复一样，停一小会儿才再出现「正在输入」
            await pause(0.45)
            await engine.demoReply("笑死我了", as: persona, in: convo, context: context)
            await pause(2.5)
            // 侧滑一点点就松手：弹回来
            await drag(router, to: 0.22, seconds: 0.35)
            router.swipeBack(velocity: 0)
            await pause(1.5)
            // 侧滑过半松手：带着速度滑出去
            await drag(router, to: 0.5, seconds: 0.4)
            router.swipeAway(velocity: 1.2)
            await pause(2)
            router.open(.chat(convo.id), from: row)
            await pause(2.2)
            router.closeChat()
        }
    }

    /// 模拟手指往右拖：一帧一帧改侧滑进度
    private static func drag(_ router: Router, to target: CGFloat, seconds: Double) async {
        let frames = Int(seconds * 60)
        for i in 1...frames {
            router.chatSwipe = target * CGFloat(i) / CGFloat(frames)
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// 画一张亮色照片当背景（带点模糊），看得出上下有没有被切掉
    private static func useWallpaper() {
        let size = CGSize(width: 1170, height: 2532)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(red: 0.98, green: 0.86, blue: 0.88, alpha: 1).cgColor,
                          UIColor(red: 0.80, green: 0.88, blue: 0.98, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            UIColor.white.withAlphaComponent(0.55).setFill()
            for i in 0..<14 {
                let r = CGFloat(60 + (i * 37) % 120)
                ctx.cgContext.fillEllipse(in: CGRect(x: CGFloat((i * 263) % 1100), y: CGFloat((i * 397) % 2450), width: r, height: r))
            }
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        WallpaperStore.save(data)
        UserDefaults.standard.set(10.0, forKey: Prefs.wallpaperBlurOf(nil))
        UserDefaults.standard.set(WallpaperStore.Choice.photo.rawValue, forKey: Prefs.wallpaper)
    }
}
