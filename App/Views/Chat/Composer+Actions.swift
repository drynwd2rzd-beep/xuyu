import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 输入栏的动作：切换面板、发文字、放进待发区、发文件和表情、打电话、语音输入
extension Composer {
    // MARK: - 动作

    /// 点加号或表情图标：在面板、键盘之间切换（输入框始终停在同一个位置）
    func toggle(_ p: Panel) {
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

    /// 加号面板里的「@」：在输入框末尾加一个 @，弹出成员列表
    func mention() {
        draft += "@"
        focused = true
    }

    /// 发出输入框里的话，连同待发区的照片和文件
    func sendText() {
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
        let hasImages = staged.contains { $0.kind == .image }
        let items = staged
        withAnimation(Motion.spring) { staged = [] }
        onSend(text, hasImages ? .images : .file, items)
    }

    /// 选好的照片先放进待发区，收起面板、弹出键盘，方便再配一句话
    func stage(_ datas: [Data]) {
        let images = datas.compactMap { ImageUtil.downscale($0) }
        guard !images.isEmpty else { return }
        let start = staged.count
        let items = images.enumerated().map { OutgoingAttachment(kind: .image, name: "photo-\(start + $0.offset + 1).jpg", data: $0.element) }
        withAnimation(Motion.spring) { staged += items.prefix(max(0, 9 - staged.count)) }
        focused = true
    }

    /// 打语音电话：TA 要先有声音（角色设置里选），还要连着电脑
    func startCall() {
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

    /// 麦克风按钮：开始或停止语音输入（说的话接在原来打的字后面）
    func toggleDictation() {
        Task {
            if dictation.isRecording {
                dictation.stop()
            } else {
                dictationBase = draft
                if let error = await dictation.start() { alert = error }
            }
        }
    }

    /// 表情面板里点一张表情：直接发出去，并记下最近用过
    func sendSticker(_ sticker: Sticker) {
        sticker.lastUsedAt = .now
        sendTick += 1
        onSend("", .sticker, [OutgoingAttachment(kind: .image, name: "sticker.png", data: sticker.data)])
    }

    /// 从「文件」里选的：图片当照片放进待发区，别的文件也先放进待发区
    func sendFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            alert = "读取文件失败。"
            return
        }
        guard data.count <= Limits.Files.attachment else {
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
        withAnimation(Motion.spring) { staged.append(OutgoingAttachment(kind: .file, name: url.lastPathComponent, data: data)) }
        focused = true
    }
}
