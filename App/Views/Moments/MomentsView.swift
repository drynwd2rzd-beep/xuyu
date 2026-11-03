import SwiftUI
import SwiftData

/// 动态（照设计稿 moments.html，像 Instagram / X）：顶上大标题和发动态的笔，一排快拍，
/// 下面是帖子流——带照片的照片铺满宽，纯文字的像推文，帖子之间靠留白分开。
/// 点帖子进详情（评论都在那里，见 MomentDetailView）。帖子见 PostView，快拍见 Stories，发动态见 MomentComposer
struct MomentsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Router.self) private var router
    @Query(sort: \Moment.createdAt, order: .reverse) private var moments: [Moment]
    @Query private var personas: [Persona]
    @Query private var photos: [AlbumPhoto]
    @AppStorage(Prefs.momentsSeenAt) private var seenAt = 0.0
    @State private var composing = false
    @State private var watching: Story?
    /// 底部的 Moments 页（没有返回键）；从角色主页点进来时是推进来的一页
    let root: Bool

    init(root: Bool = false) {
        self.root = root
    }

    var body: some View {
        let people = Dictionary(personas.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pictures = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        TimelineView(.everyMinute) { ctx in
            let visible = moments.filter { $0.createdAt <= ctx.date }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    StoriesRow(stories: Story.make(visible, people: people, pictures: pictures, now: ctx.date), seenAt: seenAt,
                               onCompose: { composing = true }, onOpen: { watching = $0 })
                        .padding(.bottom, Space.item)
                    if visible.isEmpty {
                        Text("TA 们发的动态会出现在这里。")
                            .font(Typo.serif(Typo.body))
                            .foregroundStyle(Palette.inkSoft)
                            .padding(.horizontal, Space.page)
                            .padding(.top, Space.group)
                    }
                    ForEach(visible) { m in
                        PostView(moment: m, people: people, pictures: pictures, now: ctx.date,
                                 onOpen: { comment in router.open(.moment(m.id, comment: comment)) },
                                 onProfile: { id in router.open(.momentsOf(id)) })
                    }
                }
                .padding(.bottom, Space.bookBottom)
            }
            .scrollIndicators(.hidden)
        }
        .background(Palette.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $composing) {
            MomentComposer()
                .presentationCornerRadius(Radius.sheet)
                .presentationBackground(Palette.paper)
        }
        .fullScreenCover(item: $watching) { StoryViewer(story: $0) }
        // 底部这一页一直开着（只是看不见）：切进来、切走时才算看过
        .onAppear { if !root || router.tab == .moments { seenAt = Date.now.timeIntervalSince1970 } }
        .onDisappear { seenAt = Date.now.timeIntervalSince1970 }
        .onChange(of: router.tab) { old, new in
            if root && (old == .moments || new == .moments) { seenAt = Date.now.timeIntervalSince1970 }
        }
    }

    /// 「动态 Moments」：细字、宽字距，旁边一个很淡的英文；右边是发动态的笔
    /// 「动态 Momenta」；从别处推进来的这一页，标题上面多一个返回
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !root {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: Icon.back, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: Space.control, height: Space.control)
                }
                .accessibilityLabel("返回")
                .padding(.horizontal, Space.tight)
            }
            PageHeading(title: "动态", latin: "Momenta") {
                Button { composing = true } label: {
                    Image(systemName: "plus.square")
                        .font(.system(size: Icon.compose))
                        .foregroundStyle(Palette.ink)
                        .frame(width: Space.control, height: Space.control)
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel("发动态")
            }
        }
    }
}
