import SwiftUI
import UIKit

enum MDBlock {
    case paragraph(String)
    case heading(Int, String)
    case item(indent: Int, marker: String, text: String)
    case quote(String)
    case code(lang: String, code: String)
    case table([[String]])
    case rule
}

/// 轻量 Markdown 块级解析：段落、标题、列表、引用、代码块、表格、分隔线。
/// 行内样式（粗体、斜体、行内代码、链接）交给 AttributedString。
enum MarkdownParser {
    static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [[String]] = []
        var code: [String] = []
        var codeLang = ""
        var inCode = false

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inCode {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(lang: codeLang, code: code.joined(separator: "\n")))
                    code = []
                    inCode = false
                } else {
                    code.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                inCode = true
                codeLang = String(trimmed.dropFirst(3)).trimmed
                continue
            }
            if trimmed.isEmpty { flush(); continue }

            if trimmed.hasPrefix("|") {
                if !paragraph.isEmpty || !quote.isEmpty {
                    let pending = table; table = []; flush(); table = pending
                }
                let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmed }
                let isDivider = cells.allSatisfy { cell in !cell.isEmpty && cell.allSatisfy { "-:".contains($0) } }
                if !isDivider { table.append(cells) }
                continue
            } else if !table.isEmpty {
                blocks.append(.table(table)); table = []
            }

            if let heading = heading(trimmed) { flush(); blocks.append(heading); continue }
            if ["---", "***", "___"].contains(trimmed) { flush(); blocks.append(.rule); continue }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) { flush(); blocks.append(item); continue }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            paragraph.append(trimmed)
        }
        // 流式输出时代码块可能尚未闭合
        if inCode { blocks.append(.code(lang: codeLang, code: code.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ s: String) -> MDBlock? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = s.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(hashes, String(rest.dropFirst()))
    }

    private static func listItem(_ line: String) -> MDBlock? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let rest = line.dropFirst(indent)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return .item(indent: indent / 2, marker: "•", text: String(rest.dropFirst(2)))
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if let p = after.first, p == "." || p == ")", after.dropFirst().first == " " {
                return .item(indent: indent / 2, marker: digits + ".", text: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    /// 是否需要按 Markdown 排版（否则当普通聊天文字显示）
    static func looksRich(_ text: String) -> Bool {
        let markers = ["```", "\n#", "**", "\n- ", "\n* ", "\n1. ", "\n> ", "|", "`"]
        return text.hasPrefix("#") || text.hasPrefix(">") || markers.contains { text.contains($0) }
    }

    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}

struct MarkdownView: View {
    let text: String
    var fontSize: CGFloat = 16

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .paragraph(let s):
            paragraphText(s)
        case .heading(let level, let s):
            Text(MarkdownParser.inline(s))
                .font(Typo.serif(level <= 1 ? fontSize + 5 : level == 2 ? fontSize + 3 : fontSize + 1, .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        case .item(let indent, let marker, let s):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker)
                    .font(.system(size: fontSize, weight: marker == "•" ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(Palette.inkSoft)
                paragraphText(s)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let s):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Palette.faint.opacity(0.6)).frame(width: 3)
                Text(MarkdownParser.inline(s))
                    .font(Typo.serif(fontSize - 0.5))
                    .italic()
                    .foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let lang, let code):
            CodeBlockView(lang: lang, code: code)
        case .table(let rows):
            TableBlockView(rows: rows, fontSize: fontSize - 1.5)
        case .rule:
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func paragraphText(_ s: String) -> some View {
        Text(MarkdownParser.inline(s))
            .font(.system(size: fontSize))
            .foregroundStyle(Palette.ink)
            .lineSpacing(3.5)
            .tint(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct CodeBlockView: View {
    let lang: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.inkSoft)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.inkSoft)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.success, trigger: copied) { _, new in new }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle().fill(Palette.hairline).frame(height: 0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

struct TableBlockView: View {
    let rows: [[String]]
    let fontSize: CGFloat

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            Text(MarkdownParser.inline(c < row.count ? row[c] : ""))
                                .font(.system(size: fontSize, weight: index == 0 ? .semibold : .regular))
                                .foregroundStyle(Palette.ink)
                        }
                    }
                    if index == 0 {
                        Rectangle().fill(Palette.hairline).frame(height: 0.5).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(12)
        }
        .background(Palette.fill.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}
