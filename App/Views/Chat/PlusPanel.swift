import SwiftUI
import UIKit

/// 加号菜单（照苹果短信）：聊天变磨砂，从加号往上浮出一列选项——彩色圆图标 + 大字，加号转成叉。
/// 点一项就收起菜单去做那件事；点磨砂处收起。菜单项由 Composer+Menu 给出
struct PlusMenu: View {
    struct Item: Identifiable {
        /// 显示的名字（也当 id）
        let title: String
        let symbol: String
        /// 圆图标的渐变：深色、浅色
        let tint: (Color, Color)
        let action: () -> Void
        var id: String { title }
    }

    let items: [Item]
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button(action: item.action) { row(item) }
                    .buttonStyle(ScaleButtonStyle())
                    .opacity(shown ? 1 : 0)
                    // 从加号那里长出来：越靠近加号的越先出现。减弱动态效果时只淡入（MOTION-3）
                    .scaleEffect(shown || Motion.reduced ? 1 : 0.6, anchor: .bottomLeading)
                    .offset(y: shown || Motion.reduced ? 0 : Space.page)
                    .animation(Motion.spring.delay(Double(items.count - 1 - index) * Motion.stagger), value: shown)
            }
        }
        .onAppear { shown = true }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: Space.section) {
            Image(systemName: item.symbol)
                .font(.system(size: Icon.menuGlyph, weight: .medium))
                .foregroundStyle(Palette.onUserBubble)
                .frame(width: Icon.menuCircle, height: Icon.menuCircle)
                .background(RadialGradient(colors: [item.tint.1, item.tint.0], center: UnitPoint(x: 0.38, y: 0.3),
                                           startRadius: 0, endRadius: Icon.menuCircle * 0.7), in: Circle())
            Text(LocalizedStringKey(item.title))
                .font(.system(size: Typo.title))
                .tracking(Typo.tracking)
                .foregroundStyle(Palette.ink)
        }
        .frame(minHeight: Space.row)
        .padding(.trailing, Space.page)
        .contentShape(Rectangle())
    }
}

/// 加号菜单打开时盖在聊天上的磨砂：点一下收起菜单
struct PlusVeil: View {
    let onClose: () -> Void

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Palette.frosted.opacity(0.5))
            .contentShape(Rectangle())
            .onTapGesture(perform: onClose)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("收起")
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onImage(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
