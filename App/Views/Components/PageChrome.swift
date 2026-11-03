import SwiftUI

/// 页头背景：页头本身是纸色，下方再延伸一段柔和淡出，内容滚上来不会和标题叠在一起
struct HeaderFade: View {
    var fade: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            Palette.paper
            LinearGradient(colors: [Palette.paper, Palette.paper.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: fade)
        }
        .padding(.bottom, -fade)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}

/// 屏幕上下边缘的纸色渐变：由浓到淡，中间几段放缓，看起来是自然地隐去而不是一条分界线
struct EdgeFade: View {
    let edge: VerticalEdge

    var body: some View {
        LinearGradient(stops: [
            .init(color: Palette.paper.opacity(0.97), location: 0),
            .init(color: Palette.paper.opacity(0.86), location: 0.3),
            .init(color: Palette.paper.opacity(0.55), location: 0.6),
            .init(color: Palette.paper.opacity(0.2), location: 0.85),
            .init(color: Palette.paper.opacity(0), location: 1),
        ], startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 根页面的大标题
struct PageTitle<Trailing: View>: View {
    var caption: String? = nil
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if let caption {
                    Text(caption).font(Typo.serif(15)).foregroundStyle(Palette.inkSoft)
                }
                Text(title)
                    .font(Typo.display(40))
                    .tracking(-0.6)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 2)
    }
}

/// 分区小标签：很小的灰字、大字距（AI、App、提醒……），和设计稿一样不加粗、不用衬线
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: Typo.caption))
            .tracking(Typo.labelTracking)
            .foregroundStyle(Palette.inkSoft)
            .padding(.leading, Space.tight)
            .padding(.top, Space.tight)
    }
}
