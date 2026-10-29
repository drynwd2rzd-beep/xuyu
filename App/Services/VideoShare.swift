import Foundation
import SwiftData
import Observation
import UIKit

/// 刷视频分享：TA 刷 B 站（公开的热门接口，不用登录）挑一个视频分享给你；看抖音热搜分享一个话题；
/// 你粘贴抖音分享链接给 TA，聊天里显示成视频卡片。TA 看不到画面，靠标题、简介、标签、封面聊。
/// 卡片信息存在本机一个小文件里（消息 ID → 卡片），不改数据库
@Observable
final class VideoCards {
    static let shared = VideoCards()

    struct Card: Codable, Hashable {
        enum Source: String, Codable { case bilibili, douyin, douyinHot }
        var source: Source
        var title: String
        var author = ""
        var cover = ""
        /// 点卡片打开的地址
        var url: String
    }

    private(set) var byMessage: [UUID: Card] = [:]
    @ObservationIgnored private let file: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        file = dir.appendingPathComponent("video-cards.json")
        reload()
    }

    /// 从文件读（打开时、从备份恢复后）
    func reload() {
        byMessage = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([UUID: Card].self, from: $0) } ?? [:]
    }

    func card(_ id: UUID) -> Card? { byMessage[id] }

    func set(_ card: Card, for id: UUID) {
        byMessage[id] = card
        if let data = try? JSONEncoder().encode(byMessage) { try? data.write(to: file, options: .atomic) }
    }

    func clear() {
        byMessage = [:]
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - 你发来的抖音分享

    private static let douyinLink = try! Regex("https?://v\\.douyin\\.com/[A-Za-z0-9_\\-]+/?")

    /// 抖音「复制链接」出来的那段字：「3.52 复制打开抖音，看看【某某的作品】文案 #话题 https://v.douyin.com/xxx/」
    static func douyin(in text: String) -> Card? {
        guard let link = text.firstMatch(of: douyinLink) else { return nil }
        let url = String(text[link.range])
        var author = ""
        var caption = text.replacingCharacters(in: link.range, with: "")
        if let open = caption.range(of: "【"), let close = caption.range(of: "】", range: open.upperBound..<caption.endIndex) {
            author = String(caption[open.upperBound..<close.lowerBound]).replacingOccurrences(of: "的作品", with: "")
            caption = String(caption[close.upperBound...])
        }
        caption = caption.replacingOccurrences(of: "复制打开抖音，看看", with: "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmed
        return Card(source: .douyin, title: caption.isEmpty ? String(localized: "抖音视频") : String(caption.prefix(80)), author: author, url: url)
    }

    // MARK: - TA 刷到的

    private static let lastShareKey = "video.lastShare"

    /// 每天最多一次：某位开了「刷视频分享」的角色，挑一个 B 站热门视频或一个抖音热搜，配一句话，排在今天晚些时候发来
    @MainActor
    static func maybeShare(context: ModelContext, relay: RelayClient) async {
        // 免打扰时段不刷（刷到了也别半夜发来）
        guard relay.isConnected, !DemoMode.isOn, !Prefs.isQuiet(.now), !Prefs.isQuiet(.now.addingTimeInterval(600)) else { return }
        let last = UserDefaults.standard.double(forKey: lastShareKey)
        guard Date.now.timeIntervalSince1970 - last > 20 * 3600, Double.random(in: 0..<1) < 0.6 else { return }
        let personas = context.allPersonas().filter { !$0.canWork && HumanTouch.shareVideos($0) }
        guard let persona = personas.randomElement() else { return }
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: lastShareKey)
        let useHot = Double.random(in: 0..<1) < 0.3
        let options: [Card] = useHot ? await douyinHot() : await bilibiliPopular()
        guard !options.isEmpty else { return }
        let list = options.enumerated().map { "\($0.offset + 1). \($0.element.title)" + ($0.element.author.isEmpty ? "" : "（\($0.element.author)）") }
            .joined(separator: "\n")
        let life = World.life(persona.id)
        let prompt = """
        你在\(useHot ? "看抖音热搜" : "刷 B 站")，下面是你刷到的：
        \(list)

        \(life.role.isEmpty ? "" : "你是：\(life.role)。")挑一个你真觉得有意思、或者觉得\(PromptBuilder.userName)会喜欢的，分享给 TA，配一句随口的话（比如「笑死，这只猫跟你一模一样」）。你看不到视频画面，只按标题说，别编具体画面。
        都没意思就只输出：不分享
        否则只输出 JSON：{"index":编号,"text":"你说的那句话"}
        """
        guard let raw = try? await relay.complete(Companion.lightRequest(persona, prompt)), !raw.contains("不分享"),
              let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let data = String(raw[start...end]).data(using: .utf8),
              let pick = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let index = (pick["index"] as? Int) ?? (pick["index"] as? String).flatMap(Int.init),
              options.indices.contains(index - 1),
              let text = (pick["text"] as? String)?.trimmed, !text.isEmpty else { return }
        let card = options[index - 1]
        let convo = context.chat(for: persona)
        // 已经排着别的消息（晚回、补一句、主动来找你）：这次就不发了，免得和那几条撞在一起
        let last = convo.visibleMessages().last
        guard convo.plannedMessages().isEmpty, last?.role != .user || last?.kind == .call else { return }
        // 排在今天晚些时候（像 TA 刷到时随手发来），避开免打扰
        var deliver = Date.now.addingTimeInterval(Double.random(in: 600...5400))
        if Prefs.isQuiet(deliver) { deliver = Date.now.addingTimeInterval(600) }
        // TA 这会儿在睡觉：等醒了再「刷到」
        deliver = World.awake(deliver, for: persona.id)
        let m = Message(role: .assistant, content: text, personaID: persona.id)
        m.isProactive = true
        m.relayID = "video"
        m.createdAt = deliver
        convo.add(m, context: context)
        context.persist()
        VideoCards.shared.set(card, for: m.id)
        Reminders.scheduleProactive(messageID: m.id, conversationID: convo.id, title: persona.name, body: text, at: deliver)
    }

    private struct BiliPopular: Decodable {
        struct DataPart: Decodable { var list: [Item] }
        struct Item: Decodable {
            struct Owner: Decodable { var name: String }
            var title: String
            var bvid: String
            var pic: String
            var owner: Owner
            var desc: String?
        }
        var data: DataPart?
    }

    /// B 站热门（公开接口）
    static func bilibiliPopular() async -> [Card] {
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/popular?ps=20&pn=1") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let list = (try? JSONDecoder().decode(BiliPopular.self, from: data))?.data?.list else { return [] }
        return list.map { Card(source: .bilibili, title: $0.title, author: $0.owner.name, cover: $0.pic.replacingOccurrences(of: "http://", with: "https://"),
                               url: "https://www.bilibili.com/video/\($0.bvid)") }
    }

    private struct DouyinHot: Decodable {
        struct Word: Decodable { var word: String }
        var word_list: [Word]?
    }

    /// 抖音热搜榜（不是官方公开的接口，哪天失效了就拿不到，自动不分享）
    static func douyinHot() async -> [Card] {
        guard let url = URL(string: "https://www.iesdouyin.com/web/api/v2/hotsearch/billboard/word/") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let words = (try? JSONDecoder().decode(DouyinHot.self, from: data))?.word_list else { return [] }
        return words.prefix(20).map { w in
            let q = w.word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? w.word
            return Card(source: .douyinHot, title: w.word, url: "snssdk1128://search/result?keyword=\(q)")
        }
    }

    /// 点卡片：抖音热搜先试着直接打开抖音搜这个话题，没装抖音就用网页
    @MainActor
    static func open(_ card: Card) {
        guard let url = URL(string: card.url) else { return }
        UIApplication.shared.open(url) { ok in
            guard !ok, card.source == .douyinHot,
                  let web = URL(string: "https://www.douyin.com/search/" + (card.title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")) else { return }
            UIApplication.shared.open(web)
        }
    }
}
