import SwiftUI
import SwiftData
import UIKit

/// 聊天页里长按消息（和点消息上的东西）能做的事：复制、多选、删除、重新生成、引用、撤回、编辑、拍一拍……
extension ChatView {
    // MARK: - 长按动作

    var actions: MessageActions {
        MessageActions(
            copy: { text in
                UIPasteboard.general.string = text
                flash("已复制")
            },
            select: { m in
                withAnimation(Motion.spring) {
                    selecting = true
                    picked = [m.id]
                }
            },
            toggle: { m in
                if picked.contains(m.id) { picked.remove(m.id) } else { picked.insert(m.id) }
            },
            delete: { m in deleteMessages([m.id]) },
            regenerate: { m in engine.regenerate(m, in: convo, members: members, context: context) },
            addTodo: { text in addTodo(text) },
            openImages: { attachments, index in
                viewer = ImageViewerItem(attachments: attachments, index: index)
            },
            retry: { m in engine.regenerate(m, in: convo, members: members, context: context) },
            stop: { engine.stop(convo) },
            quote: { m in quote(m) },
            recall: { m in
                // 撤回：留一行「你撤回了一条消息」；TA 还没开口的话会重新看一遍再回
                withAnimation(Motion.bubble) { m.recalled = true }
                context.persist()
                engine.reconsider(convo, members: members, context: context)
            },
            openQuote: { m in openQuote(of: m) },
            selectText: { text in selectableText = SelectableTextItem(text: text) },
            edit: { m in edit(m) },
            nudge: { p in
                engine.nudge(p, in: convo, members: members, context: context)
                pinBottom += 1
            }
        )
    }

    /// 加进待办：第一行非空的话当标题，太长的整段放进备注
    private func addTodo(_ text: String) {
        let line = text.components(separatedBy: "\n").first(where: { !$0.trimmed.isEmpty })?.trimmed ?? text
        let item = TodoItem(title: String(line.prefix(60)), notes: text.count > 60 ? text : "")
        context.insert(item)
        context.persist()
        flash("已加入待办")
    }

    /// 引用：把「谁：说了什么」放到输入框上方，发送时一起带上
    private func quote(_ m: Message) {
        let who = m.role == .user ? "我" : (m.personaID.flatMap { personaMap[$0]?.name } ?? "AI")
        let body: String = switch m.kind {
        case .images: "[图片]" + (m.content.isEmpty ? "" : " " + m.content)
        case .file: "[文件] " + m.sortedAttachments.map(\.fileName).joined(separator: "、")
        case .sticker: "[表情]"
        case .voice: "[语音] " + m.content
        case .note, .text, .nudge, .call: m.content
        }
        withAnimation(Motion.spring) { quoting = "\(who)：" + body.replacingOccurrences(of: "\n", with: " ").prefix(120) }
        quotingID = m.id
        pinBottom += 1
    }

    /// 点引用：跳到原文并让它亮一下；原文太早没加载时先把更早的消息加载出来
    private func openQuote(of m: Message) {
        let all = convo.visibleMessages()
        let earlier = all.filter { $0.createdAt < m.createdAt }
        guard let target = ReplyText.source(ofQuote: m.quote, id: m.quoteID, in: earlier) else {
            flash("原消息已经不在了")
            return
        }
        let id = target.id
        if let index = all.firstIndex(where: { $0.id == id }) { visibleLimit = max(visibleLimit, all.count - index + 10) }
        // 等更早的消息排好版再滚过去
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            scrollTarget = id
        }
        withAnimation(Motion.spring) { highlighted = id }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(Motion.glide) { if highlighted == id { highlighted = nil } }
        }
    }

    /// 编辑：把原话（连同引用）放回输入框，原消息去掉，改好再发
    private func edit(_ m: Message) {
        quotingID = m.quoteID
        withAnimation(Motion.spring) {
            draft = m.content
            quoting = m.quote.isEmpty ? nil : m.quote
            Cleanup.deleteMessages([m], context: context)
        }
        engine.reconsider(convo, members: members, context: context)
        inputFocused = true
        pinBottom += 1
    }

    /// 删消息：正在打字的那条不删（还在写）；删掉的消息上的心声、视频卡片、通话内容、待发通知一起清（Cleanup）
    func deleteMessages(_ ids: Set<UUID>) {
        let doomed = (convo.messages ?? []).filter { ids.contains($0.id) && engine.buffers[$0.id] == nil }
        withAnimation(Motion.spring) { Cleanup.deleteMessages(doomed, context: context) }
    }
}
