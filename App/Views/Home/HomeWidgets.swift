import SwiftUI
import SwiftData
import PhotosUI

struct SmallWidget<Content: View>: View {
    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading) {
            Text(caption).font(Typo.serif(13)).foregroundStyle(Palette.inkSoft)
            Spacer(minLength: 0)
            content
        }
        .padding(Space.card)
        .frame(maxWidth: .infinity, minHeight: 136, maxHeight: 136, alignment: .leading)
        .card()
    }
}

struct WhisperWidget: View {
    @AppStorage(Prefs.whisperText) private var text = ""
    @AppStorage(Prefs.whisperAuthor) private var author = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.card) {
            Label("today's whisper", systemImage: "sparkle")
                .font(Typo.serif(13))
                .foregroundStyle(Palette.onNoir.opacity(0.6))
            Text(text.isEmpty ? "连上电脑后，Claude 每天会在这里留一句话给你。" : text)
                .font(Typo.serif(20))
                .lineSpacing(6)
                .foregroundStyle(Palette.onNoir)
                .fixedSize(horizontal: false, vertical: true)
            if !author.isEmpty {
                Text("— \(author)")
                    .font(Typo.serif(13).italic())
                    .foregroundStyle(Palette.onNoir.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(Space.card + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.noir)
                .shadow(color: .black.opacity(0.14), radius: 16, y: 10)
        }
    }
}

struct DaysWidget: View {
    @Query(sort: \Persona.createdAt) private var personas: [Persona]
    @Query(sort: \Message.createdAt) private var messages: [Message]

    private var start: Date {
        min(messages.first?.createdAt ?? .now, personas.first?.createdAt ?? .now)
    }

    var body: some View {
        let days = (Calendar.current.dateComponents([.day], from: start.startOfDay, to: Date.now.startOfDay).day ?? 0) + 1
        SmallWidget(caption: "us") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Day \(days)").font(Typo.display(32)).tracking(-0.5).foregroundStyle(Palette.ink)
                Text("从 \(Fmt.ymd.string(from: start)) 开始").font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
            }
        }
    }
}

struct TodoProgressWidget: View {
    @Query private var items: [TodoItem]

    var body: some View {
        let start = Date.now.startOfDay, end = start.adding(days: 1)
        let today = items.filter { item in
            if item.isDone { return (item.completedAt ?? .distantPast) >= start }
            return (item.dueDate ?? .distantPast) < end
        }
        let done = today.filter(\.isDone).count
        let next = today.filter { !$0.isDone }.sorted(by: TodoItem.order).first
        SmallWidget(caption: "today") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: Space.item) {
                    ZStack {
                        Circle().stroke(Palette.fill, lineWidth: 5)
                        Circle()
                            .trim(from: 0, to: today.isEmpty ? 0 : CGFloat(done) / CGFloat(today.count))
                            .stroke(Palette.ink, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(done)/\(today.count)").font(Typo.serif(15)).foregroundStyle(Palette.ink)
                    }
                    .frame(width: 50, height: 50)
                    Text("件待办\n完成了").font(.system(size: 13)).foregroundStyle(Palette.ink)
                }
                Text(next.map { "下一件 · \($0.title)" } ?? "今天都做完了")
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSoft).lineLimit(1)
            }
        }
    }
}

struct DiaryWidget: View {
    @Query(sort: \DiaryEntry.day, order: .reverse) private var entries: [DiaryEntry]
    @Query(sort: \Persona.createdAt) private var personas: [Persona]

    var body: some View {
        let entry = entries.first { $0.author == .ai && !$0.text.isEmpty && $0.text != "……" }
        // 作者已经删了：写「已删除的角色」，不署别人的名字
        let name = entry?.personaID.map { id in personas.first { $0.id == id }?.name ?? String(localized: "已删除的角色") }
            ?? personas.first?.name ?? "Claude"
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack(spacing: Space.tight) {
                Text("\(name) 的日记").font(Typo.serif(17, .medium)).foregroundStyle(Palette.ink)
                if let mood = entry?.mood, !mood.isEmpty { MoodTag(text: mood) }
                Spacer()
                Chevron()
            }
            Text(entry?.text ?? "今晚 8 点以后，\(name) 会根据你们的聊天写下今天的日记。")
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(Palette.ink2)
                .lineLimit(2)
        }
        .padding(Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct MoodTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(Palette.fill, in: Capsule())
    }
}

struct CountdownWidget: View {
    @Query(filter: #Predicate<TodoItem> { !$0.isDone }) private var items: [TodoItem]

    var body: some View {
        let tomorrow = Date.now.startOfDay.adding(days: 1)
        let next = items.filter { ($0.dueDate ?? .distantPast) >= tomorrow }.min { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        let days = next?.dueDate.map { Calendar.current.dateComponents([.day], from: Date.now.startOfDay, to: $0.startOfDay).day ?? 0 }
        SmallWidget(caption: "countdown") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(days.map(String.init) ?? "–").font(Typo.display(38)).foregroundStyle(Palette.ink)
                    Text("天").font(.system(size: 13)).foregroundStyle(Palette.ink)
                }
                Text(next.map { "距离 \($0.title)" } ?? "没有即将到来的事")
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSoft).lineLimit(1)
            }
        }
    }
}

struct MoodWidget: View {
    @Query(sort: \DiaryEntry.day, order: .reverse) private var entries: [DiaryEntry]

    /// 最近 7 天每天的心情：优先用你自己日记里选的，没选就用 TA 日记里的
    private var week: [(day: Date, level: CGFloat?, mood: String)] {
        let today = Date.now.startOfDay
        return (0..<7).map { offset in
            let day = today.adding(days: offset - 6)
            let same = entries.filter { $0.day == day && !$0.mood.isEmpty }
            let pick = same.first { $0.author == .me } ?? same.first
            return (day, pick.map { Self.height($0.mood) }, pick?.mood ?? "")
        }
    }

    var body: some View {
        let days = week
        let latest = days.last { $0.level != nil }
        SmallWidget(caption: "this week") {
            VStack(alignment: .leading, spacing: 6) {
                MoodCurve(levels: days.map(\.level))
                    .frame(height: 46)
                HStack(spacing: 0) {
                    ForEach(days.indices, id: \.self) { i in
                        Text(Fmt.weekday.string(from: days[i].day).replacingOccurrences(of: "周", with: ""))
                            .font(.system(size: 9))
                            .foregroundStyle(i == days.count - 1 ? Palette.ink : Palette.faint)
                            .frame(maxWidth: .infinity)
                    }
                }
                Text(latest.map { "最近的心情 · \($0.mood)" } ?? "TA 写日记时会记下心情")
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSoft).lineLimit(1)
            }
        }
    }

    /// 心情的高低：开心最高，低落最低
    static func height(_ mood: String) -> CGFloat {
        if ["开心", "兴奋", "满足"].contains(mood) { return 0.95 }
        if ["惬意", "温柔", "安心"].contains(mood) { return 0.78 }
        if ["平静"].contains(mood) { return 0.6 }
        if ["累了", "疲惫", "无聊"].contains(mood) { return 0.38 }
        return 0.18
    }
}

/// 一周心情曲线：有记录的日子连成一条平滑的线，没记录的日子断开；最新一天的点大一点
struct MoodCurve: View {
    let levels: [CGFloat?]
    @State private var drawn: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let step = w / CGFloat(max(levels.count, 1))
            let points: [CGPoint?] = levels.enumerated().map { i, level in
                level.map { CGPoint(x: step * (CGFloat(i) + 0.5), y: 4 + (h - 8) * (1 - $0)) }
            }
            ZStack {
                // 平滑曲线：相邻两天都有记录才连线
                Path { path in
                    var previous: CGPoint?
                    for point in points {
                        guard let point else { previous = nil; continue }
                        if let previous {
                            let mid = (previous.x + point.x) / 2
                            path.addCurve(to: point, control1: CGPoint(x: mid, y: previous.y), control2: CGPoint(x: mid, y: point.y))
                        } else {
                            path.move(to: point)
                        }
                        previous = point
                    }
                }
                .trim(from: 0, to: drawn)
                .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                ForEach(Array(points.enumerated()), id: \.offset) { i, point in
                    if let point {
                        let last = i == points.lastIndex(where: { $0 != nil })
                        Circle()
                            .fill(last ? Palette.ink : Palette.card)
                            .overlay(Circle().strokeBorder(Palette.ink, lineWidth: 1.5))
                            .frame(width: last ? 9 : 6, height: last ? 9 : 6)
                            .position(point)
                            .opacity(drawn)
                    }
                }
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { drawn = 1 } }
    }
}

struct MemoryWidget: View {
    @Query(filter: #Predicate<Attachment> { $0.kindRaw == "image" }) private var images: [Attachment]

    var body: some View {
        let pick = images.last
        ZStack(alignment: .bottomLeading) {
            if let pick, let image = cachedImage(pick.data, key: pick.id.uuidString) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Palette.fill
                Image(systemName: "photo").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("memory").font(Typo.serif(13).italic()).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 4)
                .padding(14)
        }
        .frame(maxWidth: .infinity, minHeight: 136, maxHeight: 136)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .background { CardShadow() }
    }
}

/// 主页的动态：最新一条的一句话（像引言）、谁发的，右边一张歪着的拍立得；上面是没看过的那几位的头像
struct MomentsWidget: View {
    @Query(sort: \Moment.createdAt, order: .reverse) private var moments: [Moment]
    @Query private var personas: [Persona]
    @Query private var photos: [AlbumPhoto]
    @AppStorage(Prefs.momentsSeenAt) private var seenAt = 0.0

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let visible = moments.filter { $0.createdAt <= ctx.date && $0.personaID != nil }
            let latest = visible.first
            let fresh = visible.filter { $0.createdAt.timeIntervalSince1970 > seenAt }
            let posters = fresh.compactMap { m in personas.first { $0.id == m.personaID } }.reduce(into: [Persona]()) { list, p in
                if !list.contains(where: { $0.id == p.id }) { list.append(p) }
            }
            HStack(alignment: .center, spacing: Space.item) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: Space.tight) {
                        Text("moments").font(Typo.serif(13)).foregroundStyle(Palette.inkSoft)
                        if !posters.isEmpty {
                            HStack(spacing: -6) {
                                ForEach(posters.prefix(3)) { AvatarView(persona: $0, size: 20, ring: true) }
                            }
                        }
                    }
                    if let latest {
                        let name = personas.first { $0.id == latest.personaID }?.name ?? ""
                        Text("“\(Self.excerpt(latest.text))”")
                            .font(Typo.serif(19))
                            .lineSpacing(4)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("— \(name), \(Fmt.hm.string(from: latest.createdAt))")
                            .font(Typo.serif(13).italic())
                            .foregroundStyle(Palette.inkSoft)
                    } else {
                        Text("TA 们发的动态会出现在这里。")
                            .font(Typo.serif(17))
                            .foregroundStyle(Palette.ink2)
                    }
                }
                Spacer(minLength: 0)
                if let id = latest?.photoIDs.first, let photo = photos.first(where: { $0.id == id }) {
                    Polaroid(photo: photo, width: 92, height: 104, tilt: 4, border: 4)
                        .padding(.trailing, 2)
                }
            }
            .padding(.leading, Space.card + 4)
            .padding(.trailing, Space.card)
            .padding(.vertical, Space.card + 2)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
            .card()
        }
    }

    /// 取第一句；太长就截一段
    static func excerpt(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        if let end = flat.firstIndex(where: { "。！？!?".contains($0) }), flat.distance(from: flat.startIndex, to: end) <= 34 {
            return String(flat[..<end])
        }
        return flat.count > 34 ? String(flat.prefix(32)) + "…" : flat
    }
}
