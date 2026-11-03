import SwiftUI

/// 加号菜单里有哪几项：单聊有语音通话、一起听、一起读；群聊有「成员」（@ 谁）。
/// 照片放在最下面，离加号最近
extension Composer {
    var menuItems: [PlusMenu.Item] {
        var items: [PlusMenu.Item] = []
        if convo.isGroup {
            items.append(item("成员", "at", Palette.Menu.mention) { mention() })
        } else {
            items.append(item("语音通话", "phone.fill", Palette.Menu.call) { startCall() })
            items.append(item("一起听", "music.note", Palette.Menu.listen) { showListen = true })
            items.append(item("一起读", "book.fill", Palette.Menu.read) { showRead = true })
        }
        items.append(item("写想法", "pencil", Palette.Menu.note) { showNote = true })
        items.append(item("文件", "doc.fill", Palette.Menu.file) { showFiles = true })
        items.append(item("相机", "camera.fill", Palette.Menu.camera) { showCamera = true })
        items.append(item("照片", "photo.fill", Palette.Menu.photo) { showPhotos = true })
        return items
    }

    /// 点一项：先收起菜单，再做那件事
    private func item(_ title: String, _ symbol: String, _ tint: (Color, Color), _ action: @escaping () -> Void) -> PlusMenu.Item {
        PlusMenu.Item(title: title, symbol: symbol, tint: tint) {
            withAnimation(Motion.spring) { panel = nil }
            action()
        }
    }
}
