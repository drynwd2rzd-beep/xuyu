import SwiftUI
import SwiftData
import UIKit

/// 聊天页的消息列表：排哪些行由 ChatRows 算好，这里只负责画出来，并管跟随最新消息的滚动
extension ChatView {
    // MARK: - 消息

    func messageList(now: Date) -> some View {
        let layout = ChatRows.make(convo, limit: visibleLimit, buffers: engine.buffers, now: now)
        return ScrollViewReader { proxy in
            messageScroll(layout, now: now, proxy: proxy)
                // 最下面一截变了（新的一行冒出来、小点变成文字）：和你发消息时一样，带着动画滚到最新，
                // 和气泡撑开用同一条曲线（Motion.bubble，不弹），两者同时开始、同时到位，上面的消息平稳上移。
                // 不能指望「内容变高也贴着底部」：录屏里 TA 的回复一直长在输入框下面，聊天一动不动
                // TA 的：只在你正看着最新消息时跟，往上翻着时不打扰
                .onChange(of: layout.tail) {
                    guard follow else { return }
                    withAnimation(Motion.bubble) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: layout.last?.id) {
                    // 你自己刚发的（包括 TA 正在输入时插的话）：不管翻到哪儿都回到最新
                    guard layout.last?.role == .user else { return }
                    follow = true
                    withAnimation(Motion.bubble) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: keyboardShown) { _, shown in
                    // 键盘升起：一定回到最新；键盘收起：在跟随时也贴回底部，不会留下一大片空白
                    if shown { follow = true }
                    guard follow else { return }
                    withAnimation(Motion.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: panel == nil) { _, closed in
                    // 表情/加号面板收起后，在跟随时贴回底部
                    guard closed, follow else { return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(60))
                        withAnimation(Motion.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    follow = false
                    withAnimation(Motion.spring) { proxy.scrollTo(target, anchor: .center) }
                    scrollTarget = nil
                }
        }
    }

    /// 滚动区本身：点一下或手指一碰就收起面板和键盘；记下你是不是停在底部附近
    private func messageScroll(_ layout: ChatRows, now: Date, proxy: ScrollViewProxy) -> some View {
        ScrollView {
            messageStack(layout, now: now, proxy: proxy)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // 不再让系统在「内容变高」时自己贴底：它和下面带动画的滚到最新各算各的，真机录屏里整列消息会先往下掉一截再往上窜。
        // 跟随最新消息只靠下面那一处（最下面一截变了就带动画滚过去）
        .scrollDismissesKeyboard(.interactively)
        // 点一下聊天区域：收起表情/加号面板和键盘
        .simultaneousGesture(TapGesture().onEnded {
            if panel != nil { withAnimation(Motion.spring) { panel = nil } }
            if keyboardShown {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        })
        .onScrollPhaseChange { old, phase in
            switch phase {
            case .interacting:
                // 手指一碰聊天记录，表情/加号面板就收起（和键盘一样）
                if panel != nil { withAnimation(Motion.spring) { panel = nil } }
            case .idle:
                // 只有你自己翻动后停下来才重新判断：在底部附近就继续跟随，翻到上面就不打扰
                //（程序自动滚动、键盘升降引起的滚动不算，免得误以为你往上翻了）
                if old == .interacting || old == .decelerating { follow = atBottom }
            default:
                break
            }
        }
        .onAppear {
            // 打开聊天（包括从顶部提示点进来）就停在最新的消息。图片解码后变高，由「内容变高也贴着底部」跟上；
            // 不再隔一会儿补滚几次：那几下正好落在进场动画里，看起来像抽了一下
            follow = true
            proxy.scrollTo("bottom", anchor: .bottom)
        }
        .onChange(of: pinBottom) {
            // 点输入框、打开表情或加号面板：聊天跟着到最底下
            follow = true
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                withAnimation(Motion.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height + geo.contentInsets.bottom - 120
        } action: { _, value in
            atBottom = value
        }
    }

    /// 一行行排下来：最上面是「查看更早的消息」，最下面是滚动的落点
    private func messageStack(_ layout: ChatRows, now: Date, proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            if layout.hasEarlier {
                Button("查看更早的消息") { visibleLimit += 120 }
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.inkSoft)
                    .padding(.vertical, Space.item)
            }
            ForEach(layout.rows) { row in
                Group {
                    rowContent(row, receipt: layout.receipt, groupEnds: layout.groupEnds, now: now)
                }
                // 靠近页头、输入栏的这一行跟着变糊（透明度由 ChatEdgeMask 管）
                .modifier(EdgeBlur(headerBottom: headerBottom, barTop: barTop))
            }
            Color.clear.frame(height: Space.item).id("bottom")
        }
        .padding(.horizontal, Space.item)
        // 回复逐字出现时，跟着往下走（你往上翻看时不打扰）
        .background { StreamFollower(buffer: layout.live) { if follow { proxy.scrollTo("bottom", anchor: .bottom) } } }
    }

    /// 一行的样子：时间、撤回、拍一拍，或者一条消息（你最后一条下面挂「已读」）
    @ViewBuilder
    private func rowContent(_ row: ChatRow, receipt: UUID?, groupEnds: Set<String>, now: Date) -> some View {
        switch row.kind {
        case .stamp(let date):
            Text(date.separatorStamp)
                .font(.system(size: 12))
                .foregroundStyle(Palette.inkSoft)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.item)
        case .message(let m, _) where m.recalled:
            RecalledLine(message: m, onEdit: actions.edit)
                .id(m.id)
        case .message(let m, _) where m.kind == .nudge:
            NudgeLine(message: m, name: m.personaID.flatMap { personaMap[$0]?.name } ?? "")
                .id(m.id)
        case .message(let m, let first):
            MessageRow(message: m,
                       persona: m.personaID.flatMap { personaMap[$0] },
                       isGroup: convo.isGroup,
                       first: first,
                       last: groupEnds.contains(row.id),
                       selecting: selecting,
                       picked: picked.contains(m.id),
                       actions: actions)
            // 从引用跳过来时，原文这一条轻轻亮一下
            .background {
                RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                    .fill(Palette.highlight.opacity(highlighted == m.id ? 0.6 : 0))
                    .padding(-4)
            }
            // 同一组里的气泡挨得很近，组和组之间留一段（像 iMessage）
            .padding(.top, first ? Space.section : Space.bubbleGap)
            // 刚发出、刚收到的：这一行慢慢撑开，气泡从自己那一边的下角冒出来；你发的从输入框那里升上来
            .riseIn(fresh: now.timeIntervalSince(m.createdAt) < 3,
                    anchor: m.role == .user ? .bottomTrailing : .bottomLeading,
                    rise: m.role == .user ? 22 : 0)
            .id(m.id)
            if m.id == receipt { ReadReceipt() }
        }
    }
}

/// 只观察正在生成的那一条，字数变化时通知外面跟着滚动（不会让整个列表重绘）
private struct StreamFollower: View {
    let buffer: StreamBuffer?
    let follow: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: buffer?.text.count ?? 0) { follow() }
            .onChange(of: buffer?.reasoning.count ?? 0) { follow() }
    }
}
