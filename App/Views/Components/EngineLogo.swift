import SwiftUI

/// 贴纸图标：圆形贴纸，右上角翻起一个角（单色，跟随全局墨色）
struct StickerGlyph: View {
    var size: CGFloat = 20

    var body: some View {
        let s = size / 24
        ZStack {
            StickerBody().stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.6 * s, lineJoin: .round))
            StickerFlap().fill(Palette.ink.opacity(0.14))
            StickerFlap().stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.6 * s, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// 24×24 设计稿坐标换算到实际大小
    fileprivate static func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + x / 24 * rect.width, y: rect.minY + y / 24 * rect.height)
    }
}

private struct StickerBody: Shape {
    func path(in rect: CGRect) -> Path {
        let p = { (x: CGFloat, y: CGFloat) in StickerGlyph.point(x, y, in: rect) }
        var path = Path()
        path.move(to: p(12, 3))
        // 从顶部沿左边、下边绕到右侧
        path.addArc(center: p(12, 12), radius: rect.width * 9 / 24, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: true)
        path.addQuadCurve(to: p(12, 3), control: p(14.6, 9.4))
        path.closeSubpath()
        return path
    }
}

private struct StickerFlap: Shape {
    func path(in rect: CGRect) -> Path {
        let p = { (x: CGFloat, y: CGFloat) in StickerGlyph.point(x, y, in: rect) }
        var path = Path()
        path.move(to: p(12, 3))
        path.addQuadCurve(to: p(21, 12), control: p(14.6, 9.4))
        path.addQuadCurve(to: p(12, 3), control: p(11.2, 12.8))
        path.closeSubpath()
        return path
    }
}

/// Claude / Codex（OpenAI）官方标志，无背景。图形来自 simple-icons。
struct EngineLogo: View {
    let engine: Engine
    var size: CGFloat = 15

    var body: some View {
        Group {
            switch engine {
            case .claude:
                Image("ClaudeLogo").resizable().scaledToFit()
            case .codex:
                Image("CodexLogo").renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(Palette.ink)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(engine.label)
    }
}
