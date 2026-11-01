import Foundation
import SwiftData
import SwiftUI
import UIKit

// MARK: - 回复里的小标记、发回的文件、通知

extension ChatEngine {
    /// 处理 TA 回复里的小标记，返回去掉标记后的文字：
    /// 【引用:…】把你说过的那句话挂在 TA 这条消息下面；【表情:分类】从你的表情库里挑一个，单独一条跟在后面；
    /// 【约定:时间|事情】【取消约定:事情】记下或撤掉约定（到点 TA 真的来找你）
    func applyMarkers(_ text: String, to message: Message, persona: Persona, convo: Conversation,
                      context: ModelContext) -> String {
        let markers = ReplyText.markers(in: text)
        if let key = markers.quoteKey, let quoted = ReplyText.quoted(key, in: convo.visibleMessages()) {
            message.quote = ReplyText.quoteLine(for: quoted)
            message.quoteID = quoted.id
        }
        for what in markers.cancels { Appointments.cancel(what, persona: persona, convo: convo, context: context) }
        for promise in markers.promises {
            Appointments.promise(promise, persona: persona, convo: convo, context: context, relay: relay)
        }
        // TA 提起自己的动态：消息上附上 TA 最近那条
        if markers.moment, let latest = context.visibleMoments(by: persona.id).first { message.momentID = latest.id }
        // 换了称呼、闹别扭、和好
        HumanTouch.apply(markers, persona: persona)
        // 一起听时 TA 点了一首：排在下一首
        if let song = markers.song, !song.isEmpty { ListenTogether.shared.request(song) }
        // 心声：开了「内心想法」才留着，显示在这条气泡上方
        if let thought = markers.thought, !thought.isEmpty, HumanTouch.thoughts(persona) {
            Cleanup.saveThought(String(thought.prefix(Limits.Prompt.thought)), for: message.id, context: context)
        }
        // TA 拍了拍你：跟在这句后面一行小字
        if markers.pat { patBack(persona, in: convo, context: context, after: message.createdAt) }
        // TA 看了你发的表情：记下它是什么样（写在你那条表情消息里，界面上不显示，聊天记录里 TA 下次就知道）
        if let note = markers.stickerNote, !note.isEmpty,
           let sticker = convo.visibleMessages().last(where: { $0.role == .user && $0.kind == .sticker && $0.content.isEmpty }) {
            sticker.content = String(note.prefix(40))
        }
        // TA 分享相册里的一张照片：单独一条图片消息，跟在这句话后面
        if let number = markers.photo, let photo = HumanTouch.takePhoto(number, persona: persona, context: context) {
            addSingle(.images, Attachment(kind: .image, fileName: "photo.jpg", data: photo.data, order: 0), from: persona, in: convo,
                      at: max(.now, message.createdAt).addingTimeInterval(0.000005), context: context)
        }
        let stickers = markers.stickerPacks.isEmpty ? [] : (try? context.fetch(FetchDescriptor<Sticker>())) ?? []
        for pack in markers.stickerPacks {
            // 找不到这个分类就不发
            guard let pick = stickers.filter({ $0.pack == pack }).randomElement() else { continue }
            addSingle(.sticker, Attachment(kind: .image, fileName: "sticker.png", data: pick.data, order: 0), from: persona, in: convo,
                      at: max(.now, message.createdAt).addingTimeInterval(0.00001), context: context)
        }
        return markers.body
    }

    /// 电脑发回来的文件：图片显示成照片，其他显示成文件卡片。名字先清理成单纯的文件名（FileName）
    func deliver(file rawName: String, data: Data, from persona: Persona, in convo: Conversation, context: ModelContext) {
        let name = FileName.safe(rawName)
        let ext = (name as NSString).pathExtension.lowercased()
        let isImage = ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext)
        addSingle(isImage ? .images : .file, Attachment(kind: isImage ? .image : .file, fileName: name, data: data, order: 0),
                  from: persona, in: convo, context: context)
        context.persist()
    }

    /// TA 这边多出一条只带一个附件的消息（相册照片、表情、电脑发回的文件），和上面的消息一起平滑地让开。
    /// at：排在什么时候（不给就是现在）。以前三处各写一份（审查 Z-274）
    private func addSingle(_ kind: MessageKind, _ attachment: Attachment, from persona: Persona, in convo: Conversation,
                           at createdAt: Date? = nil, context: ModelContext) {
        let m = Message(role: .assistant, kind: kind, content: "", personaID: persona.id)
        if let createdAt { m.createdAt = createdAt }
        withAnimation(Motion.bubble) {
            convo.add(m, context: context)
            attachment.message = m
            context.insert(attachment)
        }
    }

    /// 回复好了：在别的页面时顶部滑下提示；App 在后台时发系统通知
    func notify(convo: Conversation, persona: Persona, text: String) {
        let title = PlannedMessages.title(persona, in: convo)
        if UIApplication.shared.applicationState != .active {
            Reminders.notifyReply(conversationID: convo.id, title: title, body: text)
            return
        }
        guard router?.openConversation != convo.id else { return }
        banners?.show(.init(conversationID: convo.id, title: title, body: text, tint: persona.tint, initial: persona.initial))
    }
}
