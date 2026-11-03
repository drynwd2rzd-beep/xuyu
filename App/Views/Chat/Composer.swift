import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

/// 聊天页的输入栏：加号、输入框（里面有表情、发送 / 语音），加号菜单和下面的表情面板。
/// 这里管布局和面板切换；发送、选照片、打电话这些动作见 Composer+Actions，@ 列表和待发区见 Composer+Lists，
/// 加号菜单有哪几项见 Composer+Menu
struct Composer: View {
    /// 输入栏打开的东西：加号菜单（浮在聊天上）、表情面板（在输入框下面，和键盘一样高）
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

    @Environment(\.modelContext) var context
    @Environment(RelayClient.self) var relay
    /// 正在打的语音电话（单聊）
    @State var call: CallSession? = nil
    /// 待发的照片和文件：可以再打字，和文字一起发
    @State var staged: [OutgoingAttachment] = []
    /// 正在从面板切回键盘：图标先带动画变回来（不用等键盘升起），来回都有动画
    @State var leaving: Panel? = nil
    @State private var panelDrag: CGFloat = 0
    @State private var panelAtTop = true
    @State var dictation = Dictation()
    @State var dictationBase = ""
    @State var alert: String? = nil
    @State var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State var showCamera = false
    @State var showFiles = false
    @State var showNote = false
    @State var showListen = false
    @State var showRead = false
    @State var sendTick = 0
    @FocusState var focused: Bool

    /// 图标显示的状态：正在切回键盘的那个面板，图标已经算「关上了」
    private func showing(_ p: Panel) -> Bool { panel == p && leaving != p }

    private var canSend: Bool { !draft.trimmed.isEmpty || !staged.isEmpty }
    private var mentionOpen: Bool { convo.isGroup && draft.hasSuffix("@") }

    var body: some View {
        core
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

    /// 输入区和下面的面板，连同它们的动画、发送时的轻震和焦点联动
    private var core: some View {
        VStack(spacing: 0) {
            inputArea
                // 加号菜单从加号往上浮出来，压在聊天上（聊天那边盖一层磨砂，见 ChatView）
                .overlay(alignment: .topLeading) {
                    if panel == .plus {
                        PlusMenu(items: menuItems)
                            .padding(.leading, Space.item)
                            .alignmentGuide(.top) { $0[.bottom] }
                            .transition(.opacity)
                    }
                }
            if panel == .stickers {
                // 表情面板：整宽贴住屏幕底部、和键盘一样高；背景一直铺到屏幕最下沿
                StickerPanel(onSticker: { sendSticker($0) }, atTop: $panelAtTop)
                    .frame(maxWidth: .infinity)
                    .frame(height: panelHeight, alignment: .top)
                    .background {
                        UnevenRoundedRectangle(topLeadingRadius: Radius.card, topTrailingRadius: Radius.card, style: .continuous)
                            .fill(Palette.card)
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
            HStack(alignment: .bottom, spacing: Space.tight) {
                plusButton
                field
            }
        }
        .padding(.horizontal, Space.item)
        .padding(.top, 6)
        .padding(.bottom, Space.tight)
    }

    // MARK: - 面板

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

    // 输入栏照 iMessage：左边一个浅灰的圆加号（打开时转成叉），右边是细边的输入框，
    // 表情、语音 / 发送都收在输入框里面，栏本身不加线也不加底色块

    private var plusButton: some View {
        Button { toggle(.plus) } label: {
            Image(systemName: "plus")
                .font(.system(size: Icon.plus, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .rotationEffect(.degrees(showing(.plus) ? 45 : 0))
                .frame(width: Space.field, height: Space.field)
                .background(showing(.plus) ? Palette.fill : Palette.card, in: Circle())
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel("更多")
        .accessibilityValue(showing(.plus) ? Text("开") : Text("关"))
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 2) {
            TextField("Message to \(convo.isGroup ? convo.displayTitle(members) : members.first?.name ?? "")…", text: $draft, axis: .vertical)
                .font(.system(size: Typo.bubble))
                .foregroundStyle(Palette.ink)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.vertical, Space.tight)
                .padding(.leading, Space.section)
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
                .frame(width: Icon.fieldButton, height: Space.field)
            }
            .accessibilityLabel(showing(.stickers) ? "键盘" : "表情")
            actionButton
                .padding(.trailing, 4)
        }
        .overlay(Capsule().strokeBorder(Palette.inkSoft.opacity(0.35), lineWidth: 0.5))
        .contentShape(Capsule())
    }

    /// 有内容就是蓝色的发送，没有就是语音输入（只有一个话筒图标，录音时换成蓝底的波形）。
    /// 对方回复时也能继续发，新消息会自然地接上
    @ViewBuilder
    private var actionButton: some View {
        let sending = canSend
        let filled = sending || dictation.isRecording
        Button {
            if sending { sendText() } else { toggleDictation() }
        } label: {
            ZStack {
                Circle().fill(Palette.userBubble)
                    .frame(width: Icon.send, height: Icon.send)
                    .scaleEffect(filled ? 1 + (dictation.isRecording ? CGFloat(dictation.level) * 0.15 : 0) : 0.3)
                    .opacity(filled ? 1 : 0)
                    .animation(.easeOut(duration: 0.1), value: dictation.level)
                Image(systemName: sending ? "arrow.up" : (dictation.isRecording ? "waveform" : "mic"))
                    .font(.system(size: filled ? Icon.sendGlyph : Icon.plus, weight: filled ? .bold : .regular))
                    .foregroundStyle(filled ? Palette.onUserBubble : Palette.ink2)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: Icon.fieldButton, height: Space.field)
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel(sending ? "发送" : "语音输入")
        .animation(Motion.snappy, value: filled)
    }

    /// 通话页用 fullScreenCover(item:) 打开，要一个能区分每次通话的包装
    private struct CallBox: Identifiable {
        let session: CallSession
        var id: ObjectIdentifier { ObjectIdentifier(session) }
    }
}
