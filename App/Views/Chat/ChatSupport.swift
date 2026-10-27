import SwiftUI
import SwiftData
import UIKit
import PhotosUI

// MARK: - 聊天背景

/// 聊天背景：全局一张，每个对话也可以单独设一张（owner 为对话 id）
enum WallpaperStore {
    /// 每个对话自己的背景选择；-1 表示跟随全局
    static func key(_ owner: UUID) -> String { "wallpaper.\(owner.uuidString)" }
    /// 照片每次更换都会改这个值，让界面重新读图
    static let stampKey = "wallpaperStamp"

    static func url(_ owner: UUID?) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(owner.map { "wallpaper-\($0.uuidString).jpg" } ?? "wallpaper.jpg")
    }

    static func save(_ data: Data, for owner: UUID? = nil) {
        guard let jpeg = ImageUtil.downscale(data, maxSide: 2000, quality: 0.85) else { return }
        try? jpeg.write(to: url(owner), options: .atomic)
        cache[owner] = nil
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: stampKey)
    }

    /// 对话被删除时一并清掉
    static func remove(for owner: UUID) {
        try? FileManager.default.removeItem(at: url(owner))
        cache[owner] = nil
        UserDefaults.standard.removeObject(forKey: key(owner))
    }

    /// 对话自己设了背景就用自己的，否则跟随全局
    static func resolve(for convoID: UUID, global: Int) -> (index: Int, owner: UUID?) {
        let own = UserDefaults.standard.object(forKey: key(convoID)) as? Int ?? -1
        return own >= 0 ? (own, convoID) : (global, nil)
    }

    private static var cache: [UUID?: UIImage] = [:]

    static func image(for owner: UUID? = nil) -> UIImage? {
        if let hit = cache[owner] { return hit }
        guard let data = try? Data(contentsOf: url(owner)), let image = UIImage(data: data) else { return nil }
        cache[owner] = image
        return image
    }
}

/// 页头 / 底栏下面的一层：先是渐渐加深的模糊，再叠一层和背景完全对齐的同一张图，
/// 消息滚到这里会先变模糊、再慢慢融进背景，没有分界线
struct ChatVeil: View {
    let index: Int
    let owner: UUID?
    let edge: VerticalEdge

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let screen = UIScreen.main.bounds
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                    .mask(gradient(solidUntil: 0.62))
                ChatWallpaper(index: index, owner: owner, edgeToEdge: false)
                    .frame(width: screen.width, height: screen.height)
                    .offset(x: -frame.minX, y: -frame.minY)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .clipped()
                    .mask(gradient(solidUntil: 0.38))
            }
        }
        .allowsHitTesting(false)
    }

    /// 靠边的一侧完全不透明，到 solidUntil 之后慢慢变透明
    private func gradient(solidUntil: CGFloat) -> LinearGradient {
        let stops: [Gradient.Stop] = [.init(color: .black, location: 0), .init(color: .black, location: solidUntil),
                                      .init(color: .black.opacity(0.35), location: (solidUntil + 1) / 2),
                                      .init(color: .clear, location: 1)]
        return LinearGradient(stops: stops, startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
    }
}

struct ChatWallpaper: View {
    let index: Int
    var owner: UUID? = nil
    /// 作为整页背景时铺满到屏幕边缘；放在页头里对齐用时不需要
    var edgeToEdge = true

    static let swatches: [(String, Color)] = [
        ("纸白", Palette.paper),
        ("雾灰", Color.dynamic(light: 0xE3E4E2, dark: 0x17181A)),
        ("夜墨", Color(hex: 0x1C1C1E)),
    ]

    var body: some View {
        Group {
            if index == 3, let image = WallpaperStore.image(for: owner) {
                Color.clear.overlay {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .overlay(Palette.paper.opacity(0.18))
            } else {
                Self.swatches[min(max(index, 0), 2)].1
            }
        }
        .ignoresSafeArea(edges: edgeToEdge ? .all : [])
    }
}


/// 背景选择：一排色块 + 自定义照片；owner 不为空时多一个「跟随」
struct WallpaperPicker: View {
    let owner: UUID?
    @AppStorage(WallpaperStore.stampKey) private var stamp = 0.0
    @AppStorage private var selection: Int
    @State private var item: PhotosPickerItem?

    init(owner: UUID?) {
        self.owner = owner
        if let owner {
            _selection = AppStorage(wrappedValue: -1, WallpaperStore.key(owner))
        } else {
            _selection = AppStorage(wrappedValue: 0, Prefs.wallpaper)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if owner != nil {
                pick(-1, "跟随") {
                    ZStack {
                        Palette.paper
                        Image(systemName: "circle.lefthalf.filled").font(.system(size: 17)).foregroundStyle(Palette.inkSoft)
                    }
                }
            }
            ForEach(0..<3, id: \.self) { i in
                pick(i, ChatWallpaper.swatches[i].0) { ChatWallpaper.swatches[i].1 }
            }
            PhotosPicker(selection: $item, matching: .images) {
                swatch(3, "照片") {
                    if selection == 3, let image = WallpaperStore.image(for: owner) {
                        Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }.id(stamp)
                    } else {
                        ZStack {
                            Palette.paper
                            Image(systemName: "photo").font(.system(size: 17)).foregroundStyle(Palette.inkSoft)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .sensoryFeedback(.selection, trigger: selection)
        .onChange(of: selection) { _, _ in
            // 让正在显示的聊天页立刻换上
            withAnimation(Motion.spring) { stamp = Date.now.timeIntervalSince1970 }
        }
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            Task {
                if let data = try? await picked.loadTransferable(type: Data.self) {
                    WallpaperStore.save(data, for: owner)
                    withAnimation(Motion.spring) { selection = 3 }
                }
                item = nil
            }
        }
    }

    private func pick<C: View>(_ index: Int, _ label: String, @ViewBuilder fill: () -> C) -> some View {
        Button { withAnimation(Motion.spring) { selection = index } } label: { swatch(index, label, fill: fill) }
            .buttonStyle(.plain)
    }

    private func swatch<C: View>(_ index: Int, _ label: String, @ViewBuilder fill: () -> C) -> some View {
        VStack(spacing: 6) {
            fill()
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(selection == index ? Palette.ink : Palette.hairline, lineWidth: selection == index ? 2 : 0.5))
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.inkSoft).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 记忆：它从更早的聊天里记住的事，可以直接改或删
struct MemoryEditor: View {
    @Binding var memory: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack {
                SectionLabel(text: "记忆")
                Spacer()
                if !memory.trimmed.isEmpty {
                    Button("清空") { withAnimation(Motion.spring) { memory = "" } }
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.inkSoft)
                        .padding(.trailing, 6)
                }
            }
            TextField("聊得多了，会自己记住关于你的事", text: $memory, axis: .vertical)
                .font(.system(size: 15))
                .lineSpacing(5)
                .lineLimit(2...14)
                .foregroundStyle(Palette.ink)
                .padding(Space.card)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
    }
}

/// 删除群聊 / 清空单聊
enum ConversationRemover {
    @MainActor
    static func remove(_ convo: Conversation, context: ModelContext, engine: ChatEngine) {
        engine.stop(convo)
        Companion.cancelPlannedMessages(in: convo, context: context)
        if convo.isGroup {
            WallpaperStore.remove(for: convo.id)
            context.delete(convo)
        } else {
            for m in convo.messages ?? [] { context.delete(m) }
            Memory.reset(convo)
        }
        try? context.save()
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

    private var fade: Double {
        let d = Double(abs(dragY))
        return 1 - min(d / 400, 0.6)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(fade).ignoresSafeArea()
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
    @Environment(Router.self) private var router
    @Environment(ChatEngine.self) private var engine
    @State private var confirmClear = false
    @State private var confirmDelete = false

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
                    VStack(alignment: .leading, spacing: Space.tight) {
                        SectionLabel(text: "自动讨论")
                        VStack(alignment: .leading, spacing: Space.tight) {
                            Segmented(items: [(1, "不讨论"), (2, "2 轮"), (3, "3 轮"), (5, "5 轮")], selection: $convo.discussRounds)
                            Text("你说一句后，大家会接着彼此的话聊几轮；你随时插话就会停下来听你说。")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.inkSoft)
                                .padding(.horizontal, 4)
                        }
                        .padding(Space.card)
                        .card()
                    }
                    MemoryEditor(memory: $convo.memory)
                    VStack(alignment: .leading, spacing: Space.tight) {
                        SectionLabel(text: "聊天背景")
                        WallpaperPicker(owner: convo.id)
                            .padding(Space.card)
                            .card()
                    }
                    VStack(spacing: 0) {
                        Button { confirmClear = true } label: {
                            Text("清空聊天记录")
                                .font(.system(size: 16))
                                .foregroundStyle(Palette.danger)
                                .frame(maxWidth: .infinity)
                                .frame(height: Space.row)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableRowStyle())
                        Hairline()
                        Button { confirmDelete = true } label: {
                            Text("删除群聊")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Palette.danger)
                                .frame(maxWidth: .infinity)
                                .frame(height: Space.row)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableRowStyle())
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .card()
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
                    Memory.reset(convo)
                    try? context.save()
                }
            } message: {
                Text("成员会保留，聊天记录和记忆删除后无法恢复。")
            }
            .confirmationDialog("删除这个群聊？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    dismiss()
                    // 先退出聊天页，再删数据，避免页面还在显示已删除的对话
                    if !router.path.isEmpty { router.path.removeLast() }
                    let target = convo
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        ConversationRemover.remove(target, context: context, engine: engine)
                    }
                }
            } message: {
                Text("群聊和里面的记录都会删除，无法恢复。")
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
