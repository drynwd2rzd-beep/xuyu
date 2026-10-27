import SwiftUI
import UIKit

private let avatarCache = NSCache<NSString, UIImage>()

func cachedImage(_ data: Data, key: String) -> UIImage? {
    let k = "\(key)-\(data.count)" as NSString
    if let hit = avatarCache.object(forKey: k) { return hit }
    guard let image = UIImage(data: data) else { return nil }
    avatarCache.setObject(image, forKey: k)
    return image
}

struct AvatarView: View {
    let persona: Persona?
    var size: CGFloat = 36
    var ring: Bool = false

    var body: some View {
        Group {
            if let persona, let data = persona.avatarData, let image = cachedImage(data, key: persona.id.uuidString) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let persona, persona.name == persona.engine.label {
                // 默认的 Claude / Codex 角色直接用它们的标志做头像
                ZStack {
                    Color(hex: UInt32(truncatingIfNeeded: persona.tint))
                    EngineLogo(engine: persona.engine, size: size * 0.5)
                        .environment(\.colorScheme, InitialAvatar.isLight(UInt32(truncatingIfNeeded: persona.tint)) ? .light : .dark)
                }
            } else {
                InitialAvatar(text: persona?.initial ?? "?", tint: UInt32(truncatingIfNeeded: persona?.tint ?? 0x1E1E1F), size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ring ? Palette.card : Palette.hairline, lineWidth: ring ? 1.5 : 0.5))
    }
}

struct InitialAvatar: View {
    let text: String
    let tint: UInt32
    let size: CGFloat

    var body: some View {
        ZStack {
            Color(hex: tint)
            Text(text)
                .font(Typo.serif(size * 0.44))
                .foregroundStyle(InitialAvatar.isLight(tint) ? Color(hex: 0x1B1B1C) : Color(hex: 0xF4F3EF))
        }
    }

    static func isLight(_ hex: UInt32) -> Bool {
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6
    }
}

/// 用户自己的头像：称呼的第一个字
struct UserAvatar: View {
    var size: CGFloat = 34
    @AppStorage(Prefs.nickname) private var nickname = ""

    var body: some View {
        InitialAvatar(text: nickname.trimmed.first.map(String.init) ?? "我", tint: 0xE7E3DA, size: size)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Palette.card, lineWidth: 1.5))
    }
}

/// 单聊显示角色头像；群聊叠放两位
struct ConversationAvatar: View {
    let convo: Conversation
    let members: [Persona]
    var size: CGFloat = 50

    var body: some View {
        if convo.isGroup && members.count > 1 {
            ZStack(alignment: .topLeading) {
                AvatarView(persona: members[0], size: size * 0.66)
                AvatarView(persona: members[1], size: size * 0.66, ring: true)
                    .offset(x: size * 0.34, y: size * 0.34)
            }
            .frame(width: size, height: size, alignment: .topLeading)
        } else {
            AvatarView(persona: members.first, size: size)
        }
    }
}

/// 群聊顶部：最多三位成员叠在一起
struct StackedAvatars: View {
    let members: [Persona]
    var size: CGFloat = 34

    var body: some View {
        HStack(spacing: -size * 0.35) {
            ForEach(members.prefix(3)) { p in
                AvatarView(persona: p, size: size, ring: true)
            }
        }
    }
}
