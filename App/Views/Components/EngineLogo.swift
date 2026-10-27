import SwiftUI

/// Claude 的放射状标志（无背景）
struct ClaudeMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        for i in 0..<12 {
            let angle: CGFloat = CGFloat(i) * .pi / 6 - .pi / 2
            let length: CGFloat = i.isMultiple(of: 2) ? r * 0.98 : r * 0.78
            let start: CGFloat = r * 0.14
            p.move(to: CGPoint(x: c.x + cos(angle) * start, y: c.y + sin(angle) * start))
            p.addLine(to: CGPoint(x: c.x + cos(angle) * length, y: c.y + sin(angle) * length))
        }
        return p
    }
}

/// Codex（OpenAI）的花结标志（无背景）
struct CodexMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width * 0.92, h = rect.height * 0.44
        let base = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        for i in 0..<3 {
            let t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .rotated(by: Double(i) * .pi / 3)
                .translatedBy(x: -rect.midX, y: -rect.midY)
            p.addPath(Path(ellipseIn: base), transform: t)
        }
        return p
    }
}

struct EngineLogo: View {
    let engine: Engine
    var size: CGFloat = 15

    var body: some View {
        Group {
            switch engine {
            case .claude:
                ClaudeMark().stroke(Palette.clay, style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
            case .codex:
                CodexMark().stroke(Palette.ink, lineWidth: size * 0.1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(engine.label)
    }
}
