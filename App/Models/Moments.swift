import Foundation
import SwiftData

/// 一条动态（像朋友圈）：角色发的，或者你自己发的（personaID 为空）
@Model
final class Moment {
    var id: UUID = UUID()
    /// 谁发的；你自己发的是 nil
    var personaID: UUID?
    var text: String = ""
    /// 发的时候的心情，两三个字
    var mood: String = ""
    /// 配图：相册里的照片，按顺序
    var photoIDs: [UUID] = []
    /// 语音动态：用 TA 的声音念出来的
    @Attribute(.externalStorage) var voice: Data?
    /// 喜欢这条的角色
    var likedBy: [UUID] = []
    var likedByMe: Bool = false
    /// 别的角色已经看过、点过赞或评论过（每条只看一次）
    var reacted: Bool = false
    /// 到这个时间才出现：TA 的动态提前写好，到点才发出来
    var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \MomentComment.moment) var comments: [MomentComment]? = []

    init(personaID: UUID?, text: String, mood: String = "", createdAt: Date = .now) {
        self.personaID = personaID
        self.text = text
        self.mood = mood
        self.createdAt = createdAt
    }

    var isMine: Bool { personaID == nil }

    /// 现在能看到的评论，按时间排
    func visibleComments(at now: Date = .now) -> [MomentComment] {
        (comments ?? []).filter { $0.createdAt <= now }.sorted { $0.createdAt < $1.createdAt }
    }

    /// 加一条评论：从动态这一边加，界面马上看到
    func add(_ comment: MomentComment, context: ModelContext) {
        context.insert(comment)
        if comments == nil { comments = [comment] } else { comments?.append(comment) }
    }
}

/// 动态下面的一条评论
@Model
final class MomentComment {
    var id: UUID = UUID()
    /// 谁评论的；你评论的是 nil
    var personaID: UUID?
    /// 回复的是哪个角色（nil 且 replyToMe 为假 = 直接评论这条动态）
    var replyTo: UUID?
    var replyToMe: Bool = false
    var text: String = ""
    /// 到这个时间才出现（别的角色过一会儿才来评论）
    var createdAt: Date = Date()
    var moment: Moment?

    init(personaID: UUID?, text: String, replyTo: UUID? = nil, replyToMe: Bool = false, createdAt: Date = .now) {
        self.personaID = personaID
        self.text = text
        self.replyTo = replyTo
        self.replyToMe = replyToMe
        self.createdAt = createdAt
    }
}

/// 相册里的一张照片：你给角色放的（TA 发动态时从这里挑），或者你自己发动态用的（personaID 为空）
@Model
final class AlbumPhoto {
    var id: UUID = UUID()
    var personaID: UUID?
    @Attribute(.externalStorage) var data: Data = Data()
    /// 照片里是什么，一句话：让 TA 挑配图时知道每张是什么（连上电脑后自动看图写好）
    var caption: String = ""
    var createdAt: Date = Date()

    init(personaID: UUID?, data: Data) {
        self.personaID = personaID
        self.data = data
    }
}

extension ModelContext {
    /// 全部动态（包括还没到点的），新的在前
    func allMoments() -> [Moment] {
        (try? fetch(FetchDescriptor<Moment>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
    }

    /// 现在能看到的动态，新的在前
    func visibleMoments(at now: Date = .now) -> [Moment] {
        allMoments().filter { $0.createdAt <= now }
    }

    /// 某个人现在能看到的动态（nil = 你自己的），新的在前
    func visibleMoments(by persona: UUID?, at now: Date = .now) -> [Moment] {
        visibleMoments(at: now).filter { $0.personaID == persona }
    }

    /// 某个角色的相册（nil = 你自己的）
    func album(of persona: UUID?) -> [AlbumPhoto] {
        let all = (try? fetch(FetchDescriptor<AlbumPhoto>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        return all.filter { $0.personaID == persona }
    }

    func photo(_ id: UUID) -> AlbumPhoto? {
        try? fetch(FetchDescriptor<AlbumPhoto>(predicate: #Predicate { $0.id == id })).first
    }
}
