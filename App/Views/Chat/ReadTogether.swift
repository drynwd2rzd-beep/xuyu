import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

/// 一起读：书架（导入 EPUB / TXT / PDF），点开一本书进阅读页
struct BookShelfSheet: View {
    let persona: Persona
    @State private var importing = false
    @State private var reading: Books.Book?
    @State private var failure: String?
    private var books: Books { Books.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reading with").font(Typo.serif(13).italic()).foregroundStyle(Palette.inkSoft)
                        Text(persona.name).font(Typo.display(26)).foregroundStyle(Palette.ink)
                    }
                    Spacer()
                    Button { importing = true } label: {
                        Label("导入", systemImage: "plus").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.inkInverse)
                            .padding(.horizontal, Space.card)
                            .frame(height: 36)
                            .background(Palette.ink, in: Capsule())
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
                .padding(.top, 24)

                if books.shelf.isEmpty {
                    Text("从「文件」里导入一本书（EPUB、TXT 或 PDF），和 \(persona.name) 一起读。划一段可以直接问 TA，TA 也会在书页边上留批注。")
                        .font(.system(size: 14.5)).lineSpacing(4).foregroundStyle(Palette.inkSoft)
                        .padding(Space.card)
                        .card()
                }
                ForEach(books.shelf) { book in
                    Button { open(book) } label: { bookRow(book) }
                        .buttonStyle(PressableRowStyle())
                        .contextMenu {
                            Button(role: .destructive) { books.remove(book.id) } label: { Label("从书架拿掉", systemImage: "trash") }
                        }
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.epub, .plainText, .pdf, .text]) { result in
            guard case .success(let url) = result else { return }
            do { open(try books.add(url)) } catch { failure = error.localizedDescription }
        }
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) {}
        }
        .fullScreenCover(item: $reading) { book in
            ReaderView(book: book, persona: persona)
        }
    }

    private func open(_ book: Books.Book) {
        books.update(book.id) { $0.persona = persona.id; $0.lastRead = .now }
        books.publish()
        reading = book
    }

    private func bookRow(_ book: Books.Book) -> some View {
        let s = books.state(book.id)
        return HStack(spacing: Space.item) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Palette.fill)
                .frame(width: 44, height: 60)
                .overlay { Text(String(book.title.prefix(1))).font(Typo.serif(20)).foregroundStyle(Palette.inkSoft) }
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).font(Typo.serif(17)).foregroundStyle(Palette.ink).lineLimit(2)
                Text(book.chapters.indices.contains(s.chapter) ? book.chapters[s.chapter].title : "")
                    .font(.system(size: Typo.secondary)).foregroundStyle(Palette.inkSoft).lineLimit(1)
            }
            Spacer()
            Text("\(min(100, Int(Double(s.chapter + 1) / Double(max(1, book.chapters.count)) * 100)))%")
                .font(Typo.serif(14).italic()).foregroundStyle(Palette.inkSoft)
        }
        .padding(Space.item)
        .card()
    }
}

/// 阅读页：一章一页，纸色、衬线字。长按选字 → 菜单里「问 TA」「划线」；TA 的批注用手写体插在那一段后面
struct ReaderView: View {
    let book: Books.Book
    let persona: Persona
    @Environment(\.dismiss) private var dismiss
    @Environment(RelayClient.self) private var relay
    @State private var chapter: Int
    @State private var asking: String?
    @State private var noting = false
    private var books: Books { Books.shared }

    init(book: Books.Book, persona: Persona) {
        self.book = book
        self.persona = persona
        _chapter = State(initialValue: min(Books.shared.state(book.id).chapter, book.chapters.count - 1))
    }

    var body: some View {
        let s = books.state(book.id)
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("合上书")
                Spacer()
                VStack(spacing: 1) {
                    Text(book.title).font(Typo.serif(14)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(book.chapters[chapter].title).font(.system(size: 11.5)).foregroundStyle(Palette.inkSoft).lineLimit(1)
                }
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, Space.tight)

            BookPage(text: book.chapters[chapter].text,
                     highlights: s.highlights.filter { $0.chapter == chapter }.map(\.text),
                     notes: s.notes.filter { $0.chapter == chapter },
                     noteFont: ThoughtFont.shared.ready ? ThoughtFont.name : nil,
                     onAsk: { asking = $0 },
                     onHighlight: { text in
                         books.update(book.id) { $0.highlights.append(Books.Highlight(chapter: chapter, text: text)) }
                     })
                .id(chapter)

            HStack {
                Button { go(chapter - 1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .disabled(chapter == 0)
                    .accessibilityLabel("上一章")
                Spacer()
                if noting { ProgressView().controlSize(.small) }
                Text("\(chapter + 1) / \(book.chapters.count)").font(Typo.serif(13).italic()).foregroundStyle(Palette.inkSoft)
                Spacer()
                Button { go(chapter + 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(chapter >= book.chapters.count - 1)
                    .accessibilityLabel("下一章")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Space.tight)
        }
        .background(Palette.paper.ignoresSafeArea())
        .sheet(item: Binding(get: { asking.map { AskQuote(text: $0) } }, set: { asking = $0?.text })) { q in
            AskInBook(book: book, chapter: chapter, quote: q.text, persona: persona)
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        .task(id: chapter) { await writeNotes() }
        .onAppear { ThoughtFont.shared.prepare() }
        .onDisappear { books.update(book.id) { $0.lastRead = .now }; books.publish() }
    }

    private struct AskQuote: Identifiable {
        let text: String
        var id: String { text }
    }

    private func go(_ index: Int) {
        guard book.chapters.indices.contains(index) else { return }
        chapter = index
        books.update(book.id) { $0.chapter = index; $0.lastRead = .now }
        books.publish()
    }

    /// 读到新的一章：TA 读一遍，挑两三处写批注（每章只写一次）
    private func writeNotes() async {
        let index = chapter
        guard relay.isConnected, !books.state(book.id).notedChapters.contains(index) else { return }
        noting = true
        defer { noting = false }
        let text = String(book.chapters[index].text.prefix(8000))
        let prompt = """
        你在和\(PromptBuilder.userName)一起读《\(book.title)》，这是「\(book.chapters[index].title)」：

        \(text)

        像在书页边上写批注那样，挑 2～3 处你真有感觉的地方，各写一句（你的看法、联想到的事、或者想问 TA 的），口语化、简短。
        只输出 JSON：[{"quote":"原文里连续的 6～20 个字，要一字不差","note":"你的批注"}]
        """
        guard let raw = try? await relay.complete(Companion.lightRequest(persona, prompt)),
              let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"),
              let data = String(raw[start...end]).data(using: .utf8),
              let items = try? JSONDecoder().decode([[String: String]].self, from: data) else { return }
        let body = book.chapters[index].text
        let notes = items.compactMap { item -> Books.Note? in
            guard let quote = item["quote"]?.trimmed, let note = item["note"]?.trimmed, !note.isEmpty, body.contains(quote) else { return nil }
            return Books.Note(chapter: index, quote: quote, text: note)
        }
        books.update(book.id) {
            $0.notes.append(contentsOf: notes)
            $0.notedChapters.append(index)
        }
    }
}

/// 一章的正文：系统的文字视图（能选字），长按菜单里多了「问 TA」「划线」；划过的线有浅浅的底色，TA 的批注插在那一段后面
struct BookPage: UIViewRepresentable {
    let text: String
    let highlights: [String]
    let notes: [Books.Note]
    let noteFont: String?
    let onAsk: (String) -> Void
    let onHighlight: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 22, bottom: 40, right: 22)
        view.delegate = context.coordinator
        view.attributedText = styled()
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let next = styled()
        if view.attributedText != next { view.attributedText = next }
    }

    /// 正文用宋体；划线的地方淡淡的底色；批注用手写体、浅色，接在那一段后面
    private func styled() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 9
        paragraph.paragraphSpacing = 14
        let body: [NSAttributedString.Key: Any] = [
            .font: UIFont(name: "STSongti-SC-Regular", size: 18) ?? UIFont.systemFont(ofSize: 18),
            .foregroundColor: UIColor(Palette.ink),
            .paragraphStyle: paragraph,
        ]
        let noteStyle = NSMutableParagraphStyle()
        noteStyle.lineSpacing = 4
        noteStyle.paragraphSpacing = 16
        noteStyle.firstLineHeadIndent = 14
        noteStyle.headIndent = 14
        let note: [NSAttributedString.Key: Any] = [
            .font: noteFont.flatMap { UIFont(name: $0, size: 15.5) } ?? UIFont.italicSystemFont(ofSize: 15),
            .foregroundColor: UIColor(Palette.inkSoft),
            .paragraphStyle: noteStyle,
        ]
        let out = NSMutableAttributedString()
        for line in text.components(separatedBy: "\n") where !line.trimmed.isEmpty {
            let piece = NSMutableAttributedString(string: line.trimmed + "\n", attributes: body)
            for h in highlights {
                var search = piece.string.startIndex
                while let r = piece.string.range(of: h, range: search..<piece.string.endIndex) {
                    piece.addAttribute(.backgroundColor, value: UIColor(Palette.highlight).withAlphaComponent(0.55), range: NSRange(r, in: piece.string))
                    search = r.upperBound
                }
            }
            out.append(piece)
            for n in notes where line.contains(n.quote) {
                out.append(NSAttributedString(string: "— " + n.text + "\n", attributes: note))
            }
        }
        return out
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BookPage
        init(_ parent: BookPage) { self.parent = parent }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let r = Range(range, in: textView.text) else { return nil }
            let selected = String(textView.text[r]).trimmed
            guard !selected.isEmpty else { return UIMenu(children: suggestedActions) }
            let ask = UIAction(title: String(localized: "问 TA"), image: UIImage(systemName: "bubble.left")) { [weak self] _ in
                self?.parent.onAsk(String(selected.prefix(300)))
            }
            let mark = UIAction(title: String(localized: "划线"), image: UIImage(systemName: "highlighter")) { [weak self] _ in
                self?.parent.onHighlight(String(selected.prefix(300)))
                textView.selectedRange = NSRange(location: range.location, length: 0)
            }
            return UIMenu(children: [ask, mark] + suggestedActions)
        }
    }
}

/// 在书页上直接问 TA：底下弹出一个小对话框，TA 就在书里回你（不发到聊天页）
struct AskInBook: View {
    let book: Books.Book
    let chapter: Int
    let quote: String
    let persona: Persona
    @Environment(RelayClient.self) private var relay
    @State private var question = ""
    @State private var talk: [(q: String, a: String)] = []
    @State private var waiting = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.item) {
            Text(quote)
                .font(Typo.serif(15))
                .lineSpacing(4)
                .foregroundStyle(Palette.ink2)
                .lineLimit(4)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Palette.hairline).frame(width: 2) }
                .padding(.top, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.item) {
                    ForEach(Array(talk.enumerated()), id: \.offset) { _, turn in
                        Text(turn.q).font(.system(size: 15)).foregroundStyle(Palette.ink)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        if !turn.a.isEmpty {
                            HStack(alignment: .top, spacing: Space.tight) {
                                AvatarView(persona: persona, size: 26)
                                Text(turn.a).font(.system(size: 15)).lineSpacing(4).foregroundStyle(Palette.ink)
                            }
                        }
                    }
                    if waiting {
                        HStack(spacing: Space.tight) {
                            AvatarView(persona: persona, size: 26)
                            TypingDots()
                        }
                    }
                }
            }
            HStack(spacing: Space.tight) {
                TextField("问问 \(persona.name)…", text: $question, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.horizontal, Space.card)
                    .padding(.vertical, 10)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.inkInverse)
                        .frame(width: 36, height: 36)
                        .background(question.trimmed.isEmpty ? Palette.faint : Palette.ink, in: Circle())
                }
                .disabled(question.trimmed.isEmpty || waiting)
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, Space.page)
        .padding(.bottom, Space.item)
        .onAppear { focused = true }
    }

    private func send() {
        let q = question.trimmed
        guard !q.isEmpty else { return }
        question = ""
        talk.append((q, ""))
        waiting = true
        let context = talk.dropLast().map { "\(PromptBuilder.userName)：\($0.q)\n你：\($0.a)" }.joined(separator: "\n")
        let around = String(book.chapters[chapter].text.prefix(4000))
        let prompt = """
        你和\(PromptBuilder.userName)正在一起读《\(book.title)》的「\(book.chapters[chapter].title)」。这一章的内容（节选）：
        \(around)

        TA 划出了这一段问你：「\(quote)」
        \(context.isEmpty ? "" : "刚才你们聊了：\n\(context)\n")TA 问：\(q)
        像一起读书的朋友那样回答，口语化，不长篇大论；不要剧透这一章之后的内容。只输出你的回答。
        """
        Task {
            let raw = (try? await relay.complete(Companion.lightRequest(persona, prompt)))?.trimmed ?? String(localized: "（没连上电脑，TA 暂时回不了）")
            let answer = ReplyText.markers(in: raw).body
            waiting = false
            if let last = talk.indices.last { talk[last].a = answer }
            Books.shared.update(book.id) { $0.asks.append(Books.Ask(chapter: chapter, quote: quote, question: q, answer: answer)) }
        }
    }
}
