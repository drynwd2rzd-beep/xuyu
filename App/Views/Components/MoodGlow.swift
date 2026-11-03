import SwiftUI

/// 心情是 TA 日记里写的一个词（「开心」「累了」……），这里把它归到设计稿的几种光晕颜色。
/// 没写心情时用「平静」那一套
enum MoodTint {
    static func glow(for mood: String) -> Palette.Glow {
        let word = mood.trimmed
        if word.isEmpty { return Palette.Mood.calm }
        if ["开心", "兴奋", "满足", "雀跃", "期待"].contains(where: { word.contains($0) }) { return Palette.Mood.bright }
        if ["惬意", "温柔", "安心", "想你", "甜"].contains(where: { word.contains($0) }) { return Palette.Mood.tender }
        if ["平静", "松了口气", "放松"].contains(where: { word.contains($0) }) { return Palette.Mood.calm }
        if ["累", "疲惫", "无聊", "困"].contains(where: { word.contains($0) }) { return Palette.Mood.tired }
        return Palette.Mood.low
    }
}

/// 一团会呼吸的柔光（设计稿「TA 此刻」那团光、设置里角色卡上的光）：三层颜色由浓到淡，边缘糊开，
/// 慢慢一大一小、轻轻转动。换心情时颜色渐变过去。减弱动态效果时不动（MOTION-3）
struct MoodGlow: View {
    let glow: Palette.Glow
    var size: CGFloat
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(RadialGradient(stops: [
                .init(color: glow.m1, location: 0),
                .init(color: glow.m2, location: 0.32),
                .init(color: glow.m3.opacity(0.7), location: 0.62),
                .init(color: glow.m3.opacity(0), location: 0.86),
            ], center: UnitPoint(x: 0.46, y: 0.46), startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .scaleEffect(x: breathing ? 1.04 : 0.93, y: breathing ? 0.98 : 0.95)
            .rotationEffect(.degrees(breathing ? 30 : 0))
            .blur(radius: size * 0.055)
            .animation(Motion.glide, value: glow)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Motion.breathe) { breathing = true }
            }
            .accessibilityHidden(true)
    }
}

/// 心情的小标签：日记、动态里写着的那个词
struct MoodTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: Typo.caption))
            .tracking(Typo.tracking)
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, Space.tight)
            .padding(.vertical, 2)
            .background(Palette.card, in: Capsule())
    }
}
