import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct Composer: View {
    enum Panel { case plus, stickers }

    @Binding var draft: String
    let convo: Conversation
    let members: [Persona]
    let busy: Bool
    let onSend: (String, MessageKind, [OutgoingAttachment]) -> Void
    let onStop: () -> Void

    @Environment(\.modelContext) private var context
    @State private var panel: Panel?
    @State private var dictation = Dictation()
    @State private var dictationBase = ""
    @State private var alert: String?
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var showNote = false
    @State private var sendTick = 0
    @FocusState private var focused: Bool

    private var canSend: Bool { !draft.trimmed.isEmpty }
    private var mentionOpen: Bool { convo.isGroup && draft.hasSuffix("@") }

    var body: some View {
        VStack(spacing: Space.tight) {
            if mentionOpen { mentionList.transition(.move(edge: .bottom).combined(with: .opacity)) }
            HStack(spacing: 10) {
                plusButton
                field
                actionButton
            }
            if let panel {
                Group {
                    switch panel {
                    case .plus:
                        PlusPanel(isGroup: convo.isGroup, onPhotos: sendPhotos, onCamera: { showCamera = true },
                                  onLibrary: { showPhotos = true }, onFile: { showFiles = true },
                                  onNote: { showNote = true }, onMention: { draft += "@"; self.panel = nil; focused = true })
                    case .stickers:
                        StickerPanel(onKaomoji: { draft += $0 }, onSticker: sendSticker)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Space.item)
        .padding(.top, 6)
        .padding(.bottom, Space.tight)
        .background {
            LinearGradient(stops: [.init(color: Palette.paper.opacity(0), location: 0), .init(color: Palette.paper, location: 0.35)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        }
        .animation(Motion.spring, value: panel)
        .animation(Motion.spring, value: mentionOpen)
        .sensoryFeedback(.impact(weight: .light), trigger: sendTick)
        .onChange(of: focused) { _, f in if f { withAnimation(Motion.spring) { panel = nil } } }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 9, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var datas: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { datas.append(data) }
                }
                photoItems = []
                sendPhotos(datas)
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in sendPhotos([data]) }.ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { sendFile(url) }
        }
        .sheet(isPresented: $showNote) {
            NoteComposer { text in
                onSend(text, .note, [])
                panel = nil
            }
            .presentationCornerRadius(Radius.sheet)
            .presentationBackground(Palette.paper)
        }
        .alert(alert ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        }
        .onAppear {
            dictation.onText = { text in draft = dictationBase + text }
        }
        .onDisappear { dictation.stop() }
    }

    // MARK: - 控件

    private var plusButton: some View {
        Button { toggle(.plus) } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(panel == .plus ? Palette.inkInverse : Palette.ink)
                .rotationEffect(.degrees(panel == .plus ? 45 : 0))
                .frame(width: Space.control, height: Space.control)
                .background(panel == .plus ? Palette.ink : Palette.card.opacity(0.9), in: Circle())
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 0.5))
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel("更多")
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 4) {
            TextField(convo.isGroup ? "发消息" : "给 \(members.first?.name ?? "") 发消息…", text: $draft, axis: .vertical)
                .font(.system(size: 15.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.vertical, 11)
                .padding(.leading, Space.card)
            Button { toggle(.stickers) } label: {
                Image(systemName: panel == .stickers ? "keyboard" : "face.smiling")
                    .font(.system(size: 19))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 36, height: Space.control)
            }
            .accessibilityLabel(panel == .stickers ? "键盘" : "表情")
            .padding(.trailing, 4)
        }
        .background(Palette.card.opacity(0.9), in: RoundedRectangle(cornerRadius: Space.control / 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Space.control / 2, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }

    @ViewBuilder
    private var actionButton: some View {
        let mode: Int = busy ? 0 : (canSend ? 1 : 2)
        Button {
            switch mode {
            case 0: onStop()
            case 1: sendText()
            default: toggleDictation()
            }
        } label: {
            ZStack {
                Circle().fill(Palette.ink)
                if dictation.isRecording {
                    Circle().stroke(Palette.ink.opacity(0.25), lineWidth: 6)
                        .scaleEffect(1 + CGFloat(dictation.level) * 0.35)
                        .animation(.easeOut(duration: 0.1), value: dictation.level)
                }
                Image(systemName: mode == 0 ? "stop.fill" : (mode == 1 ? "arrow.up" : (dictation.isRecording ? "waveform" : "mic")))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.inkInverse)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel(mode == 0 ? "停止" : (mode == 1 ? "发送" : "语音输入"))
        .animation(Motion.snappy, value: mode)
    }

    private var mentionList: some View {
        VStack(spacing: 0) {
            ForEach(members) { p in
                Button {
                    draft += p.name + " "
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(persona: p, size: 28)
                        Text(p.name).font(.system(size: 15)).foregroundStyle(Palette.ink)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableRowStyle())
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .card(radius: Radius.tile)
        .padding(.horizontal, 52)
    }

    // MARK: - 动作

    private func toggle(_ p: Panel) {
        withAnimation(Motion.spring) {
            if panel == p {
                panel = nil
                focused = true
            } else {
                focused = false
                panel = p
            }
        }
    }

    private func sendText() {
        dictation.stop()
        let text = draft.trimmed
        guard !text.isEmpty else { return }
        draft = ""
        sendTick += 1
        onSend(text, .text, [])
    }

    private func toggleDictation() {
        Task {
            if dictation.isRecording {
                dictation.stop()
            } else {
                dictationBase = draft
                if let error = await dictation.start() { alert = error }
            }
        }
    }

    private func sendPhotos(_ datas: [Data]) {
        let images = datas.compactMap { ImageUtil.downscale($0) }
        guard !images.isEmpty else { return }
        let items = images.enumerated().map { OutgoingAttachment(kind: "image", name: "photo-\($0.offset + 1).jpg", data: $0.element) }
        sendTick += 1
        withAnimation(Motion.spring) { panel = nil }
        onSend("", .images, items)
    }

    private func sendSticker(_ sticker: Sticker) {
        sticker.lastUsedAt = .now
        sendTick += 1
        onSend("", .sticker, [OutgoingAttachment(kind: "image", name: "sticker.png", data: sticker.data)])
    }

    private func sendFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            alert = "读取文件失败。"
            return
        }
        guard data.count <= 20 * 1024 * 1024 else {
            alert = "文件太大了（最多 20MB）。"
            return
        }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let jpeg = ImageUtil.downscale(data) {
            sendPhotos([jpeg])
            return
        }
        sendTick += 1
        withAnimation(Motion.spring) { panel = nil }
        onSend("", .file, [OutgoingAttachment(kind: "file", name: url.lastPathComponent, data: data)])
    }
}

/// 写想法：一段较长的文字，以便签卡片的样子发出
struct NoteComposer: View {
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            HStack {
                Button("取消") { dismiss() }.foregroundStyle(Palette.inkSoft)
                Spacer()
                Text("写想法").font(Typo.serif(18, .medium)).foregroundStyle(Palette.ink)
                Spacer()
                Button("发送") {
                    onSend(text.trimmed)
                    dismiss()
                }
                .fontWeight(.semibold)
                .foregroundStyle(Palette.ink)
                .disabled(text.trimmed.isEmpty)
            }
            TextEditor(text: $text)
                .font(Typo.serif(17))
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(Space.item)
                .card(radius: Radius.tile)
        }
        .padding(Space.page)
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }
}
