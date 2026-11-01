import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// 发你自己的动态：写几句、选几张照片、挑个心情
struct MomentComposer: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(RelayClient.self) private var relay
    @State private var text = ""
    @State private var mood = ""
    @State private var items: [PhotosPickerItem] = []
    @State private var photos: [Data] = []
    @FocusState private var focused: Bool

    static let moods = ["开心", "想你", "平静", "有点累", "期待"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) {
                    TextField("这一刻的想法…", text: $text, axis: .vertical)
                        .font(.system(size: 16))
                        .lineLimit(4...12)
                        .focused($focused)
                        .padding(Space.card)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.tile + 2, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.tile + 2, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
                    photoStrip
                    moodRow
                }
                .padding(Space.page)
            }
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle("New moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发表") {
                        MomentsEngine.shared.publish(text: text, mood: mood, photos: photos, context: context, relay: relay)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(text.trimmed.isEmpty && photos.isEmpty)
                }
            }
        }
        .onAppear { focused = true }
        .onChange(of: items) { _, picked in
            guard !picked.isEmpty else { return }
            Task {
                for item in picked {
                    if let data = try? await item.loadTransferable(type: Data.self), let small = ImageUtil.downscale(data) {
                        withAnimation(Motion.spring) { photos.append(small) }
                    }
                }
                items = []
            }
        }
    }

    // MARK: - 照片

    /// 选好的照片一排横着放，每张右上角能移除；不满 9 张时最后是「添加照片」
    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.tight) {
                ForEach(Array(photos.enumerated()), id: \.offset) { i, data in
                    Group {
                        if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill() } else { Palette.fill }
                    }
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Button { withAnimation(Motion.spring) { _ = photos.remove(at: i) } } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 22, height: 22).background(.black.opacity(0.5), in: Circle())
                        }
                        .padding(4)
                        .accessibilityLabel("移除")
                    }
                }
                if photos.count < 9 {
                    PhotosPicker(selection: $items, maxSelectionCount: 9 - photos.count, matching: .images) {
                        Image(systemName: "plus").font(.system(size: 20)).foregroundStyle(Palette.inkSoft)
                            .frame(width: 76, height: 76)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                                .strokeBorder(Palette.faint, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .accessibilityLabel("添加照片")
                }
            }
        }
    }

    // MARK: - 心情

    /// 几个心情标签，点一下选中，再点一下取消
    private var moodRow: some View {
        HStack(spacing: Space.tight) {
            ForEach(Self.moods, id: \.self) { m in
                Button { withAnimation(Motion.snappy) { mood = mood == m ? "" : m } } label: {
                    Text(LocalizedStringKey(m))
                        .font(.system(size: Typo.label))
                        .foregroundStyle(mood == m ? Palette.inkInverse : Palette.ink)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(mood == m ? Palette.ink : Palette.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: mood == m ? 0 : 0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
