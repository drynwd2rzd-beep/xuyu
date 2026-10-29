import Foundation
import PDFKit
import Observation

/// 一起读书：导入的书、读到哪、划的线、TA 的批注、在书页上问 TA 的话。
/// 每本书一个小文件夹（不改数据库）：book.json（书名、各章正文）和 state.json（进度、划线、批注）
@Observable
final class Books {
    static let shared = Books()

    struct Chapter: Codable, Hashable {
        var title: String
        var text: String
    }

    struct Book: Codable, Identifiable, Hashable {
        var id = UUID()
        var title: String
        var author = ""
        var chapters: [Chapter]
        var addedAt = Date()
    }

    struct Note: Codable, Hashable, Identifiable {
        var id = UUID()
        var chapter: Int
        /// 批注贴在哪几个字后面（这一章原文里的一小段）
        var quote: String
        var text: String
    }

    struct Highlight: Codable, Hashable, Identifiable {
        var id = UUID()
        var chapter: Int
        var text: String
    }

    struct Ask: Codable, Hashable, Identifiable {
        var id = UUID()
        var chapter: Int
        var quote: String
        var question: String
        var answer: String
        var at = Date()
    }

    struct State: Codable, Hashable {
        var chapter = 0
        /// 和谁一起读
        var persona: UUID?
        /// TA 的进度比你快一点或慢一点（-1、0、1 章）
        var taOffset = Int.random(in: -1...1)
        var notes: [Note] = []
        /// 已经写过批注的章
        var notedChapters: [Int] = []
        var highlights: [Highlight] = []
        var asks: [Ask] = []
        var lastRead: Date?
    }

    private(set) var shelf: [Book] = []
    private(set) var states: [UUID: State] = [:]

    private static var root: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("books", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("book.json")),
                  let book = try? JSONDecoder().decode(Book.self, from: data) else { continue }
            shelf.append(book)
            if let s = (try? Data(contentsOf: dir.appendingPathComponent("state.json"))).flatMap({ try? JSONDecoder().decode(State.self, from: $0) }) {
                states[book.id] = s
            }
        }
        shelf.sort { $0.addedAt > $1.addedAt }
    }

    func state(_ id: UUID) -> State { states[id] ?? State() }

    func update(_ id: UUID, _ change: (inout State) -> Void) {
        var s = state(id)
        change(&s)
        states[id] = s
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: Self.root.appendingPathComponent(id.uuidString).appendingPathComponent("state.json"), options: .atomic)
        }
    }

    func remove(_ id: UUID) {
        shelf.removeAll { $0.id == id }
        states[id] = nil
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(id.uuidString))
    }

    func removeAll() {
        shelf = []
        states = [:]
        try? FileManager.default.removeItem(at: Self.root)
    }

    // MARK: - 导入

    enum ImportError: LocalizedError {
        case unreadable, empty
        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "这本书打不开（有加密保护的书打不开）。")
            case .empty: String(localized: "这本书里没读出文字。")
            }
        }
    }

    /// 从「文件」里选的书：EPUB、TXT、PDF
    func add(_ url: URL) throws -> Book {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let name = url.deletingPathExtension().lastPathComponent
        var book: Book
        switch url.pathExtension.lowercased() {
        case "epub":
            guard let data = try? Data(contentsOf: url), let parsed = Epub.read(data) else { throw ImportError.unreadable }
            book = Book(title: parsed.title.isEmpty ? name : parsed.title, author: parsed.author, chapters: parsed.chapters)
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { throw ImportError.unreadable }
            var chapters: [Chapter] = []
            var page = 0
            while page < pdf.pageCount {
                let end = min(pdf.pageCount, page + 8)
                let text = (page..<end).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n\n")
                chapters.append(Chapter(title: String(localized: "第 \(page + 1)–\(end) 页"), text: text))
                page = end
            }
            book = Book(title: (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) ?? name, chapters: chapters)
        default:
            guard let data = try? Data(contentsOf: url), let text = Self.decode(data) else { throw ImportError.unreadable }
            book = Book(title: name, chapters: Self.splitChapters(text))
        }
        book.chapters = book.chapters.map { Chapter(title: $0.title, text: $0.text.trimmed) }.filter { !$0.text.isEmpty }
        guard !book.chapters.isEmpty else { throw ImportError.empty }
        let dir = Self.root.appendingPathComponent(book.id.uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(book).write(to: dir.appendingPathComponent("book.json"), options: .atomic)
        shelf.insert(book, at: 0)
        return book
    }

    /// TXT：先试 UTF-8，再试 GBK（国内的 txt 很多是 GBK）
    private static func decode(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gb))
    }

    /// TXT 按「第几章 / 第几回」分章；没有章节标题就每 6000 字一段
    static func splitChapters(_ text: String) -> [Chapter] {
        let lines = text.components(separatedBy: .newlines)
        let heading = try? Regex("^\\s*(第[0-9零一二三四五六七八九十百千两]+[章回节卷]|Chapter\\s+\\d+)")
        var chapters: [Chapter] = []
        var title = String(localized: "开始")
        var body: [String] = []
        for line in lines {
            if let heading, line.count < 40, line.firstMatch(of: heading) != nil {
                if !body.joined().trimmed.isEmpty { chapters.append(Chapter(title: title, text: body.joined(separator: "\n"))) }
                title = line.trimmed
                body = []
            } else {
                body.append(line)
            }
        }
        if !body.joined().trimmed.isEmpty { chapters.append(Chapter(title: title, text: body.joined(separator: "\n"))) }
        if chapters.count <= 1 {
            let all = text
            var parts: [Chapter] = []
            var start = all.startIndex
            var n = 1
            while start < all.endIndex {
                let end = all.index(start, offsetBy: 6000, limitedBy: all.endIndex) ?? all.endIndex
                parts.append(Chapter(title: String(localized: "第 \(n) 部分"), text: String(all[start..<end])))
                start = end
                n += 1
            }
            return parts
        }
        return chapters
    }

    // MARK: - 写进聊天的提示词

    /// 拼提示词时用（不在主线程也能读）：和这位一起读的那本书、各自读到哪
    nonisolated(unsafe) static var lines: [UUID: String] = [:]

    func publish() {
        var result: [UUID: String] = [:]
        for book in shelf {
            let s = state(book.id)
            guard let who = s.persona, let last = s.lastRead, Date.now.timeIntervalSince(last) < 10 * 86400 else { continue }
            let mine = min(s.chapter, book.chapters.count - 1)
            let ta = max(0, min(book.chapters.count - 1, mine + s.taOffset))
            let line = "你们最近在一起读《\(book.title)》：TA 读到「\(book.chapters[mine].title)」，你读到「\(book.chapters[ta].title)」。可以自然地聊起，别剧透 TA 还没读到的地方。"
            if result[who] == nil { result[who] = line }
        }
        Self.lines = result
    }
}

/// 读 EPUB：其实是一个 zip 包。按 container.xml → opf 的阅读顺序（spine）取出每一章，去掉网页标签
enum Epub {
    struct Parsed {
        var title: String
        var author: String
        var chapters: [Books.Chapter]
    }

    static func read(_ data: Data) -> Parsed? {
        let files = MiniZip.entries(data)
        guard let container = files["META-INF/container.xml"].flatMap({ String(data: $0, encoding: .utf8) }),
              let opfPath = first("full-path=\"([^\"]+)\"", in: container),
              let opf = files[opfPath].flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        let base = (opfPath as NSString).deletingLastPathComponent
        let title = first("<dc:title[^>]*>([^<]+)</dc:title>", in: opf) ?? ""
        let author = first("<dc:creator[^>]*>([^<]+)</dc:creator>", in: opf) ?? ""
        // manifest：id → 文件；spine：阅读顺序
        var manifest: [String: String] = [:]
        for item in all("<item\\s[^>]*>", in: opf) {
            if let id = first("id=\"([^\"]+)\"", in: item), let href = first("href=\"([^\"]+)\"", in: item) { manifest[id] = href }
        }
        let order = all("<itemref\\s[^>]*>", in: opf).compactMap { first("idref=\"([^\"]+)\"", in: $0) }
        var chapters: [Books.Chapter] = []
        for idref in order {
            guard let href = manifest[idref]?.removingPercentEncoding else { continue }
            let path = base.isEmpty ? href : base + "/" + href
            guard let html = files[path].flatMap({ String(data: $0, encoding: .utf8) }) else { continue }
            let text = plain(html)
            guard text.count > 20 else { continue }
            let heading = first("<h[1-3][^>]*>(.*?)</h[1-3]>", in: html).map(plain) ?? first("<title>([^<]*)</title>", in: html) ?? ""
            chapters.append(Books.Chapter(title: heading.isEmpty ? String(localized: "第 \(chapters.count + 1) 章") : String(heading.prefix(40)), text: text))
        }
        return chapters.isEmpty ? nil : Parsed(title: title.trimmed, author: author.trimmed, chapters: chapters)
    }

    /// 网页 → 纯文字：段落换行，去掉标签，常见的转义字符换回来
    static func plain(_ html: String) -> String {
        var s = html
        if let body = s.range(of: "<body", options: .caseInsensitive) { s = String(s[body.lowerBound...]) }
        for (pattern, with) in [("<(br|/p|/div|/h[1-6]|/li)[^>]*>", "\n"), ("<[^>]+>", "")] {
            s = s.replacingOccurrences(of: pattern, with: with, options: [.regularExpression, .caseInsensitive])
        }
        for (code, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            s = s.replacingOccurrences(of: code, with: char)
        }
        s = s.replacingOccurrences(of: "\n\\s*\n+", with: "\n\n", options: .regularExpression)
        return s.trimmed
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func all(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}

/// 最小的 zip 读取：只读不写，支持不压缩和 deflate（EPUB 只用这两种）
enum MiniZip {
    static func entries(_ data: Data) -> [String: Data] {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { i + 1 < bytes.count ? Int(bytes[i]) | Int(bytes[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { i + 3 < bytes.count ? u16(i) | u16(i + 2) << 16 : 0 }
        // 末尾的目录结束标记
        var end = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 65_557) {
            if u32(i) == 0x0605_4b50 { end = i; break }
            i -= 1
        }
        guard end >= 0 else { return [:] }
        let count = u16(end + 10)
        var p = u32(end + 16)
        var result: [String: Data] = [:]
        for _ in 0..<count {
            guard u32(p) == 0x0201_4b50 else { break }
            let method = u16(p + 10)
            let compressed = u32(p + 20)
            let nameLength = u16(p + 28), extra = u16(p + 30), comment = u16(p + 32)
            let local = u32(p + 42)
            let name = String(decoding: bytes[(p + 46)..<min(bytes.count, p + 46 + nameLength)], as: UTF8.self)
            p += 46 + nameLength + extra + comment
            guard u32(local) == 0x0403_4b50 else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= bytes.count else { continue }
            let raw = Data(bytes[start..<(start + compressed)])
            switch method {
            case 0: result[name] = raw
            case 8: result[name] = try? (raw as NSData).decompressed(using: .zlib) as Data
            default: continue
            }
        }
        return result
    }
}
