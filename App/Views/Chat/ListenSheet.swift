import SwiftUI
import SwiftData

/// 一起听的页面：正在放的歌、播放控制、搜歌点歌、加进你们的歌单、一起听过的歌
struct ListenSheet: View {
    let persona: Persona
    @Environment(\.modelContext) private var context
    @Environment(RelayClient.self) private var relay
    @State private var query = ""
    @State private var results: [ListenTogether.Song] = []
    @State private var searching = false
    @State private var alert: String?
    @State private var added = 0
    private var music: ListenTogether { ListenTogether.shared }

    /// 每位角色一个歌单，名字是「和 TA 一起听的歌」
    private var playlistID: UUID { persona.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                HStack(spacing: Space.item) {
                    AvatarView(persona: persona, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listening with").font(Typo.serif(13).italic()).foregroundStyle(Palette.inkSoft)
                        Text(persona.name).font(Typo.display(26)).foregroundStyle(Palette.ink)
                    }
                    Spacer()
                }
                .padding(.top, 24)

                if music.isOn { nowCard } else { startCard }

                if music.isOn {
                    SettingsGroup(title: "点歌") {
                        HStack(spacing: Space.tight) {
                            Image(systemName: "magnifyingglass").foregroundStyle(Palette.inkSoft)
                            TextField("歌名、歌手", text: $query)
                                .submitLabel(.search)
                                .onSubmit(search)
                            if searching { ProgressView().controlSize(.small) }
                        }
                        .font(.system(size: 15))
                        .padding(.horizontal, Space.card)
                        .frame(height: Space.row)
                        ForEach(results) { song in
                            Hairline()
                            songRow(song)
                        }
                    }
                }

                if !music.history.isEmpty {
                    SettingsGroup(title: "一起听过") {
                        ForEach(Array(music.history.prefix(12).enumerated()), id: \.element.id) { index, song in
                            if index > 0 { Hairline() }
                            songRow(song)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .alert(alert ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        }
        .sensoryFeedback(.success, trigger: added)
    }

    private var startCard: some View {
        VStack(alignment: .leading, spacing: Space.item) {
            Text("打开 Apple Music 放歌，\(persona.name) 就知道你们在听什么，会陪你聊、帮你点歌。锁着屏也一直在。")
                .font(.system(size: 14.5))
                .lineSpacing(4)
                .foregroundStyle(Palette.ink2)
            Button {
                Task {
                    if let error = await music.start(with: persona, context: context, relay: relay) { alert = error }
                }
            } label: {
                Text("开始一起听")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.inkInverse)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(Space.card)
        .card()
    }

    private var nowCard: some View {
        VStack(alignment: .leading, spacing: Space.item) {
            if let song = music.now {
                Text(song.title).font(Typo.serif(20, .medium)).foregroundStyle(Palette.ink).lineLimit(2)
                if !song.artist.isEmpty { Text(song.artist).font(.system(size: 14)).foregroundStyle(Palette.inkSoft) }
                ProgressView(value: music.duration > 0 ? min(1, music.position / music.duration) : 0)
                    .tint(Palette.ink)
                HStack {
                    Text(ListenTogether.clock(music.position))
                    Spacer()
                    Text(ListenTogether.clock(music.duration))
                }
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Palette.inkSoft)
            } else {
                Text("还没在放歌。打开 Apple Music 放一首，或者在下面点一首。")
                    .font(.system(size: 14.5)).foregroundStyle(Palette.inkSoft)
            }
            HStack(spacing: 28) {
                Spacer()
                control("backward.fill", "上一首") { music.previous() }
                control(music.playing ? "pause.fill" : "play.fill", music.playing ? "暂停" : "播放", big: true) { music.togglePlay() }
                control("forward.fill", "下一首") { music.next() }
                Spacer()
            }
            .padding(.vertical, 4)
            HStack {
                if let song = music.now, !song.storeID.isEmpty {
                    Button {
                        music.add(song, toPlaylist: String(localized: "和\(persona.name)一起听的歌"), id: playlistID)
                        added += 1
                    } label: {
                        Label("加进我们的歌单", systemImage: "text.badge.plus").font(.system(size: 14))
                    }
                    .foregroundStyle(Palette.ink)
                }
                Spacer()
                Button("不听了") { music.stop() }
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.inkSoft)
            }
        }
        .padding(Space.card)
        .card()
    }

    private func control(_ symbol: String, _ label: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: big ? 22 : 17))
                .foregroundStyle(big ? Palette.inkInverse : Palette.ink)
                .frame(width: big ? 58 : 44, height: big ? 58 : 44)
                .background(big ? Palette.ink : Palette.fill, in: Circle())
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel(label)
    }

    private func songRow(_ song: ListenTogether.Song) -> some View {
        HStack(spacing: Space.item) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.system(size: 15)).foregroundStyle(Palette.ink).lineLimit(1)
                if !song.artist.isEmpty { Text(song.artist).font(.system(size: 12.5)).foregroundStyle(Palette.inkSoft).lineLimit(1) }
            }
            Spacer()
            if music.isOn, !song.storeID.isEmpty {
                Button { music.playNext(song) } label: {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward").font(.system(size: 14)).foregroundStyle(Palette.inkSoft)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("下一首放这个")
                Button { music.play(song) } label: {
                    Image(systemName: "play.fill").font(.system(size: 12)).foregroundStyle(Palette.ink)
                        .frame(width: 36, height: 36)
                        .background(Palette.fill, in: Circle())
                }
                .accessibilityLabel("马上放")
            }
        }
        .padding(.horizontal, Space.card)
        .frame(minHeight: Space.row)
    }

    private func search() {
        let term = query.trimmed
        guard !term.isEmpty else { return }
        searching = true
        Task {
            results = await ListenTogether.search(term)
            searching = false
        }
    }
}
