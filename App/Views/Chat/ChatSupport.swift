import SwiftUI
import SwiftData
import UIKit

// MARK: - 聊天背景

enum WallpaperStore {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wallpaper.jpg")
    }

    static func save(_ data: Data) {
        guard let jpeg = ImageUtil.downscale(data, maxSide: 2000, quality: 0.85) else { return }
        try? jpeg.write(to: url, options: .atomic)
        cache = nil
    }

    private static var cache: UIImage?

    static var image: UIImage? {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: url) else { return nil }
        cache = UIImage(data: data)
        return cache
    }
}

struct ChatWallpaper: View {
    let index: Int

    static let swatches: [(String, Color)] = [
        ("纸白", Palette.paper),
        ("雾灰", Color.dynamic(light: 0xE3E4E2, dark: 0x17181A)),
        ("夜墨", Color(hex: 0x1C1C1E)),
    ]

    var body: some View {
        Group {
            if index == 3, let image = WallpaperStore.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .overlay(Palette.paper.opacity(0.18))
            } else {
                Self.swatches[min(max(index, 0), 2)].1
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 全屏看图

struct ImageViewerItem: Identifiable {
    let id = UUID()
    let attachments: [Attachment]
    let index: Int
}

struct ImageViewer: View {
    let item: ImageViewerItem
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var saved = false
    @State private var dragY: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(1 - min(abs(dragY) / 400, 0.6)).ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(Array(item.attachments.enumerated()), id: \.offset) { index, a in
                    ZoomableImage(image: cachedImage(a.data, key: a.id.uuidString))
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: item.attachments.count > 1 ? .automatic : .never))
            .offset(y: dragY)
            .gesture(DragGesture().onChanged { v in
                if abs(v.translation.height) > abs(v.translation.width) { dragY = v.translation.height }
            }.onEnded { v in
                if abs(v.translation.height) > 120 { dismiss() } else { withAnimation(Motion.spring) { dragY = 0 } }
            })
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(.white.opacity(0.15), in: Circle())
                }
                .accessibilityLabel("关闭")
                Spacer()
                Button {
                    guard item.attachments.indices.contains(page),
                          let image = UIImage(data: item.attachments[page].data) else { return }
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    withAnimation(Motion.spring) { saved = true }
                } label: {
                    Image(systemName: saved ? "checkmark" : "square.and.arrow.down")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(.white.opacity(0.15), in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel("保存到相册")
                .sensoryFeedback(.success, trigger: saved)
            }
            .padding(.horizontal, Space.page)
            .opacity(dragY == 0 ? 1 : 0)
        }
        .onAppear { page = item.index }
        .onChange(of: page) { saved = false }
        .statusBarHidden()
    }
}

private struct ZoomableImage: View {
    let image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var last: CGFloat = 1

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .scaleEffect(scale)
        .gesture(MagnifyGesture().onChanged { v in
            scale = max(1, min(last * v.magnification, 4))
        }.onEnded { _ in
            last = scale
        })
        .onTapGesture(count: 2) {
            withAnimation(Motion.spring) {
                scale = scale > 1 ? 1 : 2.2
                last = scale
            }
        }
    }
}

// MARK: - 群聊信息

struct GroupInfoSheet: View {
    @Bindable var convo: Conversation
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) {
                    VStack(alignment: .leading, spacing: Space.tight) {
                        SectionLabel(text: "群聊名称")
                        TextField("群聊", text: $convo.title)
                            .font(.system(size: 16))
                            .padding(.horizontal, Space.card)
                            .frame(height: Space.row)
                            .card()
                    }
                    VStack(alignment: .leading, spacing: Space.tight) {
                        SectionLabel(text: "成员")
                        VStack(spacing: 0) {
                            ForEach(personas) { p in
                                Button { toggle(p) } label: {
                                    HStack(spacing: Space.item) {
                                        AvatarView(persona: p, size: 32)
                                        Text(p.name).font(.system(size: 16)).foregroundStyle(Palette.ink)
                                        Spacer()
                                        if convo.memberIDs.contains(p.id) {
                                            Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                                        }
                                    }
                                    .padding(.horizontal, Space.card)
                                    .frame(height: Space.row)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PressableRowStyle())
                                if p.id != personas.last?.id { Hairline(inset: 60) }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .card()
                    }
                    Button { confirmClear = true } label: {
                        Text("清空聊天记录")
                            .font(.system(size: 16))
                            .foregroundStyle(Palette.danger)
                            .frame(maxWidth: .infinity)
                            .frame(height: Space.row)
                            .card()
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
                .padding(Space.page)
            }
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle("群聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        try? context.save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog("清空这个群聊的记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    for m in convo.messages ?? [] { context.delete(m) }
                    try? context.save()
                }
            } message: {
                Text("成员会保留，删除后无法恢复。")
            }
        }
    }

    private func toggle(_ p: Persona) {
        if let i = convo.memberIDs.firstIndex(of: p.id) {
            if convo.memberIDs.count > 2 { convo.memberIDs.remove(at: i) }
        } else {
            convo.memberIDs.append(p.id)
        }
    }
}
