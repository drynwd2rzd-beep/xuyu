import SwiftUI
import UIKit

/// 输入框上方的两样东西：群聊里打「@」时弹出的成员列表，选好还没发的照片和文件
extension Composer {
    // MARK: - 待发区

    /// 选好的照片和文件先放在输入框上方，可以再打字，和文字一起发
    var stagedRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.tight) {
                ForEach(Array(staged.enumerated()), id: \.offset) { index, item in
                    ZStack(alignment: .topTrailing) {
                        if item.kind == .image {
                            Group {
                                if let image = UIImage(data: item.data) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    Palette.fill
                                }
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        } else {
                            // 文件：小卡片显示文件名
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text").font(.system(size: 16)).foregroundStyle(Palette.ink)
                                Text(item.name).font(.system(size: 12)).foregroundStyle(Palette.ink2).lineLimit(2)
                            }
                            .padding(.horizontal, 10)
                            .frame(width: 132, height: 64, alignment: .leading)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
                        }
                        Button {
                            withAnimation(Motion.spring) { _ = staged.remove(at: index) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Color.black.opacity(0.55), in: Circle())
                        }
                        .padding(4)
                        .accessibilityLabel("移除")
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 52)
        }
    }

    // MARK: - @ 列表

    /// 群聊里打「@」：所有人和每位成员，点一下接在输入框后面
    var mentionList: some View {
        VStack(spacing: 0) {
            Button {
                draft += "所有人 "
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.2")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 28, height: 28)
                        .background(Palette.fill, in: Circle())
                    Text("所有人").font(.system(size: 15)).foregroundStyle(Palette.ink)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())
            ForEach(members) { p in
                Button {
                    draft += p.name + " "
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(persona: p, size: 28)
                        Text(p.name).font(.system(size: 15)).foregroundStyle(Palette.ink)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableRowStyle())
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .card(radius: Radius.tile)
        .padding(.horizontal, 52)
    }
}
