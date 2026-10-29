import SwiftUI
import SwiftData
import UIKit
import Photos
import PhotosUI

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
    /// 没能存进相册（没给权限、或者系统存失败）
    @State private var saveFailed = false
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
                    ZoomableImage(image: cachedImage(a.data, key: a.id.uuidString, maxPixel: 3000))
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
                Button(action: save) {
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
        .alert("没有存进相册", isPresented: $saveFailed) {
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text("絮语需要相册权限才能保存图片，可以在「设置」里打开。")
        }
        .statusBarHidden()
    }

    /// 存进相册：真的存好了才打勾。以前不管有没有权限都直接打勾，其实没存上
    private func save() {
        guard item.attachments.indices.contains(page),
              let image = UIImage(data: item.attachments[page].data) else { return }
        Task {
            var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
            guard status == .authorized || status == .limited else {
                saveFailed = true
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                withAnimation(Motion.spring) { saved = true }
            } catch {
                saveFailed = true
            }
        }
    }
}

struct ZoomableImage: View {
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
