import Foundation
import MediaPlayer
import AVFoundation
import SwiftData
import UIKit
import Observation

/// 一起听：和某位角色一起听 Apple Music。
/// 读得到正在放哪首、放到哪里，TA 能搜歌、给你点歌、排下一首、在你的资料库里建歌单（用 iPhone 自带的播放接口，不用 MusicKit）。
/// 歌是系统替我们放的，絮语自己照样会被暂停：开着「一起听」时，絮语在后台放一段听不见的静音，iPhone 就不会暂停它，
/// 锁着屏 TA 也一直知道你在听什么（关掉就停，不额外耗电）
@MainActor
@Observable
final class ListenTogether {
    static let shared = ListenTogether()

    struct Song: Codable, Hashable, Identifiable {
        var id: String { storeID.isEmpty ? "\(title)-\(artist)" : storeID }
        var storeID: String
        var title: String
        var artist: String
        var artwork: String = ""
        /// 和谁一起听的、什么时候（写进长期记忆用；旧记录里没有）
        var with: UUID?
        var at: Date?
    }

    /// 正在和谁一起听（nil = 没开）
    private(set) var persona: UUID?
    private(set) var now: Song?
    private(set) var playing = false
    /// 放到第几秒 / 整首多长
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    /// 一起听过的歌（最近的在前，最多 200 首）
    private(set) var history: [Song] = []

    @ObservationIgnored private let player = MPMusicPlayerController.systemMusicPlayer
    @ObservationIgnored private var keepAlive: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastComment = Date.distantPast
    @ObservationIgnored private weak var relay: RelayClient?
    @ObservationIgnored private var context: ModelContext?

    var isOn: Bool { persona != nil }

    private init() {
        reloadHistory()
    }

    /// 从文件读（打开时、从备份恢复后）
    func reloadHistory() {
        history = Storage.read([Song].self, from: .listened) ?? []
    }

    // MARK: - 开始 / 结束

    /// 返回错误提示；成功时返回 nil
    func start(with persona: Persona, context: ModelContext, relay: RelayClient) async -> String? {
        let status = await withCheckedContinuation { c in MPMediaLibrary.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else { return String(localized: "需要在系统设置里允许絮语访问 Apple Music。") }
        self.persona = persona.id
        self.context = context
        self.relay = relay
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.songChanged() }
            },
            center.addObserver(forName: .MPMusicPlayerControllerPlaybackStateDidChange, object: player, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            },
        ]
        startKeepAlive()
        refresh()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.position = self?.player.currentPlaybackTime ?? 0
                self?.publishLine()
            }
        }
        return nil
    }

    /// 角色被删了：正和 TA 一起听就停下（静音保活、换歌回调都停）
    func stop(ifWith id: UUID) {
        if persona == id { stop() }
    }

    func stop() {
        persona = nil
        Self.line = nil
        ticker?.cancel()
        ticker = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        player.endGeneratingPlaybackNotifications()
        keepAlive?.stop()
        keepAlive = nil
    }

    /// 后台一直跑：循环放一段听不见的静音（和别的声音混在一起，不打断音乐）
    private func startKeepAlive() {
        guard keepAlive == nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let silent = Self.silence(), let p = try? AVAudioPlayer(data: silent) else { return }
        p.numberOfLoops = -1
        p.volume = 0
        p.play()
        keepAlive = p
    }

    /// 一秒的静音 WAV
    private static func silence() -> Data? {
        let rate = 8000, samples = rate
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return data
    }

    // MARK: - 正在放什么

    private func refresh() {
        playing = player.playbackState == .playing
        position = player.currentPlaybackTime
        guard let item = player.nowPlayingItem else { now = nil; duration = 0; return }
        duration = item.playbackDuration
        let song = Song(storeID: item.playbackStoreID, title: item.title ?? String(localized: "未知歌曲"), artist: item.artist ?? "")
        if song.id != now?.id { now = song }
        publishLine()
    }

    private func songChanged() {
        let before = now
        refresh()
        guard var song = now, song.id != before?.id else { return }
        song.with = persona
        song.at = .now
        history.removeAll { $0.id == song.id }
        history.insert(song, at: 0)
        history = Array(history.prefix(Limits.Store.listened))
        Storage.write(history, to: .listened)
        maybeComment(on: song)
    }

    /// 拼提示词时用（拼提示词不在主线程）：和谁一起听、那一句。每秒跟着更新
    nonisolated(unsafe) static var line: (persona: UUID, text: String)?

    private func publishLine() {
        if let id = persona, let text = promptLine { Self.line = (id, text) } else { Self.line = nil }
    }

    /// 写进提示词：你们正在一起听什么
    var promptLine: String? {
        guard isOn, let song = now else { return nil }
        let at = duration > 0 ? "（放到 \(Self.clock(position)) / \(Self.clock(duration))\(playing ? "" : "，暂停着")）" : ""
        return "你们正在一起听：《\(song.title)》\(song.artist.isEmpty ? "" : " - \(song.artist)")\(at)。可以自然地聊这首歌，别每句都提；想换一首时单独写【点歌:歌名 - 歌手】，App 会帮你放。"
    }

    static func clock(_ s: Double) -> String {
        let t = Int(max(0, s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: - TA 偶尔插一句

    /// 换歌时偶尔说一句（不是每首都说，至少隔 6 分钟）：在聊天里发出来，絮语在后台时弹通知
    private func maybeComment(on song: Song) {
        guard let id = persona, let context, let relay, relay.isConnected,
              Date.now.timeIntervalSince(lastComment) > Limits.Timing.listenComment, Double.random(in: 0..<1) < 0.35,
              let persona = context.persona(id) else { return }
        lastComment = .now
        Task {
            let prompt = """
            你和\(PromptBuilder.userName)正在一起听歌（你听不到声音，但知道在放哪首）。现在开始放《\(song.title)》\(song.artist.isEmpty ? "" : " - \(song.artist)")。
            像一起听歌的朋友那样随口说一句：可以说你对这首歌的印象、它让你想起什么、或者问 TA 喜不喜欢。一句话，口语化，不要用书名号以外的引号。只输出这一句。
            """
            guard let text = await relay.attempt(Companion.lightRequest(persona, prompt), "一起听插话"),
                  !text.trimmed.isEmpty, self.persona == id else { return }
            let convo = context.chat(for: persona)
            // TA 正在打字回你：这句就不插了，不然会把那段回复从中间隔开
            guard !(convo.messages ?? []).contains(where: { $0.status == .streaming }) else { return }
            let m = Message(role: .assistant, content: ReplyText.markers(in: text).body.trimmed, personaID: persona.id)
            convo.add(m, context: context)
            convo.updatedAt = .now
            context.persist()
            if UIApplication.shared.applicationState != .active {
                Reminders.notifyReply(conversationID: convo.id, title: persona.name, body: m.content)
            }
        }
    }

    /// 写进长期记忆：这段时间和这位一起听过的歌
    func memoryLine(for id: UUID, from start: Date, to end: Date) -> String? {
        let songs = history.filter { $0.with == id && ($0.at ?? .distantPast) > start && ($0.at ?? .distantPast) <= end }
        guard !songs.isEmpty else { return nil }
        let list = songs.prefix(12).map { "《\($0.title)》\($0.artist.isEmpty ? "" : " - \($0.artist)")" }.joined(separator: "、")
        return "一起听过：\(list)"
    }

    // MARK: - 点歌

    struct Found: Decodable {
        struct Item: Decodable {
            var trackId: Int
            var trackName: String
            var artistName: String
            var artworkUrl100: String?
        }
        var results: [Item]
    }

    /// 在 Apple Music 曲库里搜（苹果公开的搜索接口，不用账号）
    static func search(_ term: String, limit: Int = 8) async -> [Song] {
        var c = URLComponents(string: "https://itunes.apple.com/search")
        c?.queryItems = [.init(name: "term", value: term), .init(name: "entity", value: "song"), .init(name: "limit", value: String(limit)),
                         .init(name: "country", value: Locale.current.region?.identifier ?? "CN")]
        guard let url = c?.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let found = try? JSONDecoder().decode(Found.self, from: data) else { return [] }
        return found.results.map { Song(storeID: String($0.trackId), title: $0.trackName, artist: $0.artistName, artwork: $0.artworkUrl100 ?? "") }
    }

    /// 马上放这首
    func play(_ song: Song) {
        guard !song.storeID.isEmpty else { return }
        player.setQueue(with: [song.storeID])
        player.play()
    }

    /// 排在下一首
    func playNext(_ song: Song) {
        guard !song.storeID.isEmpty else { return }
        if player.nowPlayingItem == nil { return play(song) }
        player.prepend(MPMusicPlayerStoreQueueDescriptor(storeIDs: [song.storeID]))
    }

    func togglePlay() { playing ? player.pause() : player.play() }
    func next() { player.skipToNextItem() }
    func previous() { player.skipToPreviousItem() }

    /// TA 回复里的【点歌:歌名 - 歌手】：搜到就排在下一首
    func request(_ query: String) {
        guard isOn else { return }
        Task {
            if let first = await Self.search(query, limit: 1).first { playNext(first) }
        }
    }

    // MARK: - 歌单

    /// 在你的 Apple Music 资料库里建（或找到）这个歌单，把歌加进去
    func add(_ song: Song, toPlaylist name: String, id: UUID) {
        guard !song.storeID.isEmpty else { return }
        let meta = MPMediaPlaylistCreationMetadata(name: name)
        meta.descriptionText = String(localized: "在絮语里一起听过的歌")
        MPMediaLibrary.default().getPlaylist(with: id, creationMetadata: meta) { playlist, _ in
            playlist?.addItem(withProductID: song.storeID) { _ in }
        }
    }
}
