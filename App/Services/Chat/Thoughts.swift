import SwiftUI
import UIKit
import CoreText
import Observation

/// TA 的内心想法（心声）：按人设心里真正想的一句话，不是模型的思考过程。
/// TA 在回复里写【心声:…】，显示在气泡上方、和工作模式「思考过程」同一个位置，平时收成一行，点一下展开。
/// 存在本机一个小文件里（消息 ID → 那句话），不改数据库；聊天记录里也带着，TA 记得自己想过什么
@Observable
final class Thoughts {
    static let shared = Thoughts()

    private(set) var byMessage: [UUID: String] = [:]
    @ObservationIgnored private let url: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("thoughts.json")
        reload()
    }

    /// 从文件读（打开时、从备份恢复后）
    func reload() {
        byMessage = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([UUID: String].self, from: $0) } ?? [:]
    }

    func text(_ id: UUID) -> String? { byMessage[id] }

    func set(_ text: String, for id: UUID) {
        byMessage[id] = text
        // 最多留 3000 条（很早以前的心声不再需要）
        if byMessage.count > 3000 { byMessage = Dictionary(uniqueKeysWithValues: byMessage.shuffled().prefix(2500).map { ($0.key, $0.value) }) }
        if let data = try? JSONEncoder().encode(byMessage) { try? data.write(to: url, options: .atomic) }
    }

    func clear() {
        byMessage = [:]
        try? FileManager.default.removeItem(at: url)
    }
}

/// 心声用的字：苹果自带、按需下载的「手札体」（像手写的小纸条，不占安装包）。还没下好时先用衬线斜体
@Observable
final class ThoughtFont {
    static let shared = ThoughtFont()
    static let name = "HannotateSC-W5"
    private(set) var ready = UIFont(name: ThoughtFont.name, size: 12) != nil
    @ObservationIgnored private var asked = false

    func font(_ size: CGFloat) -> Font {
        ready ? .custom(Self.name, size: size) : Typo.serif(size).italic()
    }

    /// 第一次要用时在后台下载一次
    func prepare() {
        guard !ready, !asked else { return }
        asked = true
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: Self.name] as CFDictionary)
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler([descriptor] as CFArray, nil) { state, _ in
            if state == .didFinish {
                DispatchQueue.main.async {
                    ThoughtFont.shared.ready = UIFont(name: ThoughtFont.name, size: 12) != nil
                }
            }
            return true
        }
    }
}

/// 气泡上方那一行心声：收着时只露一行，点一下展开全部（左边一条细线，和「思考过程」一样）
struct ThoughtLine: View {
    let text: String
    @State private var open = false
    private var font: ThoughtFont { ThoughtFont.shared }

    var body: some View {
        Button { withAnimation(Motion.spring) { open.toggle() } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(text)
                    .font(font.font(14.5))
                    .lineSpacing(3)
                    .foregroundStyle(Palette.inkSoft)
                    .lineLimit(open ? nil : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.faint)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) { Rectangle().fill(Palette.hairline).frame(width: 2) }
            .padding(.leading, 2)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("心里想：\(text)"))
        .onAppear { font.prepare() }
    }
}
