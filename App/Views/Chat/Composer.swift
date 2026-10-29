import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct Composer: View {
    enum Panel { case plus, stickers }

    @Binding var draft: String
    /// 表情 / 加号面板：放在外面，聊天页要根据它决定键盘弹出时怎么排版
    @Binding var panel: Panel?
    /// 正在引用的那句话，显示在输入框上方，发送时一起带上
    @Binding var quote: String?
    /// 面板高度和键盘一样，键盘和面板互相切换时输入框不会上下跳
    let panelHeight: CGFloat
    let convo: Conversation
    let members: [Persona]
    let onSend: (String, MessageKind, [OutgoingAttachment]) -> Void
    /// 输入框获得焦点或打开面板时通知外面（聊天滚到最底下）
    var onExpand: () -> Void = {}
    /// 输入框是不是在打字：聊天页据此判断弹出的键盘是不是给输入框的
    @Binding var inputFocused: Bool

    @Environment(\.modelContext) private var context
    @Environment(RelayClient.self) private var relay
    /// 正在打的语音电话（单聊）
    @State private var call: CallSession?
    /// 待发的照片和文件：可以再打字，和文字一起发
    @State private var staged: [OutgoingAttachment] = []
    /// 正在从面板切回键盘：图标先带动画变回来（不用等键盘升起），来回都有动画
    @State private var leaving: Panel?
    @State private var panelDrag: CGFloat = 0
    @State private var panelAtTop = true
    @State private var dictation = Dictation()
    @State private var dictationBase = ""
    @State private var alert: String?
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var showNote = false
    @State private var showListen = false
    @State private var showRead = false
    @State private var sendTick = 0
    @FocusState private var focused: Bool

    /// 图标显示的状态：正在切回键盘的那个面板，图标已经算「关上了」
    private func showing(_ p: Panel) -> Bool { panel == p && leaving != p }

    private var canSend: Bool { !draft.trimmed.isEmpty || !staged.isEmpty }
    private var mentionOpen: Bool { convo.isGroup && draft.hasSuffix("@") }

    var body: some View {
        VStack(spacing: 0) {
            inputArea
            if let panel {
                // 面板：整宽贴住屏幕底部、和键盘一样高；背景一直铺到屏幕最下沿
                panelView(panel)
                    .frame(maxWidth: .infinity)
                    .frame(height: panelHeight, alignment: .top)
                    .background {
                        UnevenRoundedRectangle(topLeadingRadius: Radius.card, topTrailingRadius: Radius.card, style: .continuous)
                            .fill(Palette.card)
                            .shadow(color: .black.opacity(0.06), radius: 16, y: -4)
                            .ignoresSafeArea(edges: .bottom)
                    }
                    .offset(y: panelDrag)
                    // 往下拉一段，面板自己收回去
                    .simultaneousGesture(panelDragGesture)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 28)),
                                            removal: .move(edge: .bottom).combined(with: .opacity)))
            }
        }
        .animation(Motion.spring, value: mentionOpen)
        .animation(Motion.spring, value: staged.count)
        .onChange(of: quote) { _, q in if q != nil { focused = true } }
        // 聊天页要求弹出键盘（比如编辑消息）
        .onChange(of: inputFocused) { _, f in if f != focused { focused = f } }
        .sensoryFeedback(.impact(weight: .light), trigger: sendTick)
        .onChange(of: focused) { _, f in
            inputFocused = f
            // 面板开着时点输入框：面板先留着，等键盘完全升起来（和面板一样高）再无缝换掉
            if f { onExpand() } else { leaving = nil }
        }
        .onChange(of: panel) { _, p in
            if p == nil || p != leaving { leaving = nil }
            panelAtTop = true
            panelDrag = 0
            if p != nil { onExpand() }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 9, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var datas: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { datas.append(data) }
                }
                photoItems = []
                stage(datas)
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in stage([data]) }.ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { sendFile(url) }
        }
        .sheet(isPresented: $showNote) {
            NoteComposer { text in
                onSend(text, .note, [])
                withAnimation(Motion.spring) { panel = nil }
            }
            .presentationCornerRadius(Radius.sheet)
            .presentationBackground(Palette.paper)
        }
        // 语音通话（单聊）：整屏深色的通话页
        .fullScreenCover(item: Binding(get: { call.map(CallBox.init) }, set: { call = $0?.session })) { box in
            CallView(session: box.session)
        }
        // 通话记录里点「再打一次」
        .onReceive(NotificationCenter.default.publisher(for: CallLogs.callAgain)) { note in
            if (note.object as? UUID) == convo.id { startCall() }
        }
        // 一起读（单聊）：书架和阅读页
        .sheet(isPresented: $showRead) {
            if let persona = members.first {
                BookShelfSheet(persona: persona)
                    .presentationDetents([.large])
                    .presentationCornerRadius(Radius.sheet)
                    .presentationBackground(Palette.paper)
            }
        }
        // 一起听（单聊）：和这位角色一起听 Apple Music
        .sheet(isPresented: $showListen) {
            if let persona = members.first {
                ListenSheet(persona: persona)
                    .presentationDetents([.large])
                    .presentationCornerRadius(Radius.sheet)
                    .presentationBackground(Palette.paper)
            }
        }
        .alert(alert ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        }
        .onAppear {
            // 停了以后才到的识别结果不要：不然发出去以后，字又被写回输入框
            dictation.onText = { text in if dictation.isRecording { draft = dictationBase + text } }
        }
        .onDisappear { dictation.stop() }
    }

    /// 输入框和它上面的 @ 列表、待发照片、引用
    private var inputArea: some View {
        VStack(spacing: Space.tight) {
            if mentionOpen { mentionList.transition(.move(edge: .bottom).combined(with: .opacity)) }
            if !staged.isEmpty { stagedRow.transition(.move(edge: .bottom).combined(with: .opacity)) }
            if let quote {
                QuoteChip(text: quote) { withAnimation(Motion.spring) { self.quote = nil } }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Space.control + Space.tight + 2)
                    .padding(.trailing, 54)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: Space.tight + 2) {
                plusButton
                field
                actionButton
            }
        }
        .padding(.horizontal, Space.item)
        .padding(.top, 6)
        .padding(.bottom, Space.tight)
    }

    // MARK: - 面板

    @ViewBuilder
    private func panelView(_ panel: Panel) -> some View {
        switch panel {
        case .plus:
            PlusPanel(isGroup: convo.isGroup, onPhotos: stage, onCamera: { showCamera = true },
                      onLibrary: { showPhotos = true }, onFile: { showFiles = true },
                      onNote: { showNote = true }, onMention: mention,
                      onCall: convo.isGroup ? nil : startCall,
                      onListen: convo.isGroup ? nil : { showListen = true },
                      onRead: convo.isGroup ? nil : { showRead = true })
        case .stickers:
            StickerPanel(onSticker: sendSticker, atTop: $panelAtTop)
        }
    }

    private func mention() {
        draft += "@"
        focused = true
    }

    /// 选好的照片和文件先放在输入框上方，可以再打字，和文字一起发
    private var stagedRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.tight) {
                ForEach(Array(staged.enumerated()), id: \.offset) { index, item in
                    ZStack(alignment: .topTrailing) {
                        if item.kind == "image" {
                            Group {
                                if let image = UIImage(data: item.data) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    Palette.fill
                                }
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        } else {
                            // 文件：小卡片显示文件名
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text").font(.system(size: 16)).foregroundStyle(Palette.ink)
                                Text(item.name).font(.system(size: 12)).foregroundStyle(Palette.ink2).lineLimit(2)
                            }
                            .padding(.horizontal, 10)
                            .frame(width: 132, height: 64, alignment: .leading)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
                        }
                        Button {
                            withAnimation(Motion.spring) { _ = staged.remove(at: index) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Color.black.opacity(0.55), in: Circle())
                        }
                        .padding(4)
                        .accessibilityLabel("移除")
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 52)
        }
    }

    private var panelDragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                let dy = v.translation.height
                guard panelAtTop, dy > 0, dy > abs(v.translation.width) else { return }
                panelDrag = dy * 0.55
            }
            .onEnded { v in
                let flick = panelAtTop && panelDrag > 0 && v.predictedEndTranslation.height > 200
                if panelDrag > 44 || flick {
                    withAnimation(Motion.spring) {
                        panel = nil
                        panelDrag = 0
                    }
                } else {
                    withAnimation(Motion.settle) { panelDrag = 0 }
                }
            }
    }

    // MARK: - 控件

    private var plusButton: some View {
        Button { toggle(.plus) } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(showing(.plus) ? Palette.inkInverse : Palette.ink)
                .rotationEffect(.degrees(showing(.plus) ? 45 : 0))
                .frame(width: Space.control, height: Space.control)
                .background(showing(.plus) ? Palette.ink : Palette.card.opacity(0.9), in: Circle())
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 0.5))
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel("更多")
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 4) {
            TextField("Message to \(convo.isGroup ? convo.displayTitle(members) : members.first?.name ?? "")…", text: $draft, axis: .vertical)
                .font(.system(size: Typo.body))
                .foregroundStyle(Palette.ink)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.vertical, 11)
                .padding(.leading, Space.card)
            Button { toggle(.stickers) } label: {
                // 两个图标一直都在，只是交替淡入淡出：跟着输入框一起移动，不会留在原地叠在一起
                ZStack {
                    StickerGlyph(size: 21)
                        .opacity(showing(.stickers) ? 0 : 1)
                        .scaleEffect(showing(.stickers) ? 0.7 : 1)
                    Image(systemName: "keyboard")
                        .font(.system(size: 17))
                        .foregroundStyle(Palette.ink)
                        .opacity(showing(.stickers) ? 1 : 0)
                        .scaleEffect(showing(.stickers) ? 1 : 0.7)
                }
                .frame(width: 36, height: Space.control)
            }
            .accessibilityLabel(showing(.stickers) ? "键盘" : "表情")
            .padding(.trailing, 4)
        }
        .background(Palette.card.opacity(0.9), in: RoundedRectangle(cornerRadius: Space.control / 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Space.control / 2, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }

    /// 有内容就是发送，没有就是语音。对方回复时也能继续发，新消息会自然地接上
    @ViewBuilder
    private var actionButton: some View {
        let sending = canSend
        Button {
            if sending { sendText() } else { toggleDictation() }
        } label: {
            ZStack {
                Circle().fill(Palette.ink)
                if dictation.isRecording {
                    Circle().stroke(Palette.ink.opacity(0.25), lineWidth: 6)
                        .scaleEffect(1 + CGFloat(dictation.level) * 0.35)
                        .animation(.easeOut(duration: 0.1), value: dictation.level)
                }
                Image(systemName: sending ? "arrow.up" : (dictation.isRecording ? "waveform" : "mic"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.inkInverse)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel(sending ? "发送" : "语音输入")
        .animation(Motion.snappy, value: sending)
    }

    private var mentionList: some View {
        VStack(spacing: 0) {
            Button {
                draft += "所有人 "
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.2")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 28, height: 28)
                        .background(Palette.fill, in: Circle())
                    Text("所有人").font(.system(size: 15)).foregroundStyle(Palette.ink)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())
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
        if panel == p {
            // 面板 → 键盘：图标马上带动画变回来；键盘升到和面板一样高后，聊天页再把面板撤掉
            withAnimation(Motion.snappy) { leaving = p }
            focused = true
        } else if focused || panel != nil {
            // 键盘 → 面板（或换另一个面板）：面板和键盘一样高，在原地淡入，输入框不动
            withAnimation(Motion.fade) { panel = p }
            focused = false
        } else {
            withAnimation(Motion.spring) { panel = p }
        }
    }

    private func sendText() {
        dictation.stop()
        let text = draft.trimmed
        guard !text.isEmpty || !staged.isEmpty else { return }
        draft = ""
        clearLeftover(of: text)
        sendTick += 1
        if staged.isEmpty {
            onSend(text, .text, [])
            return
        }
        // 照片和文件可以和文字一起发，一次发出（照片、文件都有时会自动分成两条）
        let hasImages = staged.contains { $0.kind == "image" }
        let items = staged
        withAnimation(Motion.spring) { staged = [] }
        onSend(text, hasImages ? .images : .file, items)
    }

    /// 选好的照片先放进待发区，收起面板、弹出键盘，方便再配一句话
    private func stage(_ datas: [Data]) {
        let images = datas.compactMap { ImageUtil.downscale($0) }
        guard !images.isEmpty else { return }
        let start = staged.count
        let items = images.enumerated().map { OutgoingAttachment(kind: "image", name: "photo-\(start + $0.offset + 1).jpg", data: $0.element) }
        withAnimation(Motion.spring) { staged += items.prefix(max(0, 9 - staged.count)) }
        focused = true
    }

    /// 打语音电话：TA 要先有声音（角色设置里选），还要连着电脑
    private func startCall() {
        guard let persona = members.first else { return }
        guard Voice.enabled(for: persona) else {
            alert = String(localized: "\(persona.name) 还没有声音：先在角色设置里给 TA 选一个声音。")
            return
        }
        guard relay.isConnected else {
            alert = String(localized: "要先连上电脑才能打电话。")
            return
        }
        withAnimation(Motion.spring) { panel = nil }
        focused = false
        call = CallSession(persona: persona, convo: convo, members: members, context: context, relay: relay)
    }

    private struct CallBox: Identifiable {
        let session: CallSession
        var id: ObjectIdentifier { ObjectIdentifier(session) }
    }

    /// 中文输入法还没确认的字（候选词）会在清空之后才被键盘写回来，发出去的话又出现在输入框里（有概率）：
    /// 过一小会儿再看两次，回来的正是刚发的那些字（或者它的一部分），就再清一次；你接着打的新字不动
    private func clearLeftover(of sent: String) {
        Task { @MainActor in
            for wait in [60, 250] {
                try? await Task.sleep(for: .milliseconds(wait))
                let back = draft.trimmed
                if !back.isEmpty && (back == sent || sent.hasSuffix(back) || sent.hasPrefix(back)) { draft = "" }
            }
        }
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
        // 一次发的东西是一整条传给电脑的，加起来太大会被中继拒收（上限 64MB，编码后会变大三成多）
        guard staged.reduce(data.count, { $0 + $1.data.count }) <= 40 * 1024 * 1024 else {
            alert = "这次带的文件加起来太大了（最多 40MB），分几次发吧。"
            return
        }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            stage([data])
            return
        }
        // 文件也先放进待发区，可以再配一句话一起发
        withAnimation(Motion.spring) { staged.append(OutgoingAttachment(kind: "file", name: url.lastPathComponent, data: data)) }
        focused = true
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
