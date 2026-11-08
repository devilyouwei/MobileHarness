import Foundation

#if os(iOS)
    import SwiftUI
    import UIKit

    /// One image and one bounded presentation transaction; no device or storage ownership.
    @MainActor
    @Observable
    public final class CapturedPhotoPresentation {
        public let id: String
        public let image: UIImage
        private let completed: @MainActor (Bool) -> Void
        private var acknowledged = false
        public init(id: String, image: UIImage, completed: @escaping @MainActor (Bool) -> Void) {
            self.id = id
            self.image = image
            self.completed = completed
        }
        public func finish(reachedThumbnail: Bool = false) {
            guard !acknowledged else { return }
            acknowledged = true
            completed(reachedThumbnail)
        }
    }

    /// Gallery rendering owns only bounded thumbnails and the current page/neighbors.
    @MainActor struct CameraGalleryView: View {
        @Bindable var camera: CameraState
        let controls: any CameraControlling
        @State private var selected: String?
        @State private var thumbnails: [String: UIImage] = [:]
        @State private var pages: [String: UIImage] = [:]
        @State private var failure: String?
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        private var ids: [String] { camera.previews.map(\.id) }
        private var index: Int { CameraGalleryNavigation.index(selected, in: ids) }
        private var item: CameraPreviewItem? { camera.previews.indices.contains(index) ? camera.previews[index] : nil }
        var body: some View {
            ZStack(alignment: .bottomTrailing) {
                if !ids.isEmpty {
                    Button {
                        selected = ids.last
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            ForEach(Array(ids.suffix(3).enumerated()), id: \.element) { offset, id in
                                Group {
                                    if let image = thumbnails[id] {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    } else {
                                        Color.gray.opacity(0.6)
                                    }
                                }
                                .frame(width: 72, height: 94).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.9), lineWidth: 1.5))
                                .rotationEffect(.degrees(Double(offset - 2) * -5))
                                .offset(x: CGFloat(offset - 2) * -5, y: CGFloat(offset - 2) * -5)
                            }
                            Text("\(ids.count)").font(.caption.bold()).monospacedDigit().padding(6)
                                .background(.black.opacity(0.75), in: Capsule()).offset(x: 6, y: -8)
                        }.frame(width: 86, height: 110)
                    }.buttonStyle(.plain).accessibilityLabel("查看 \(ids.count) 张预览照片")
                        .accessibilityIdentifier("camera.gallery.stack").padding(.trailing, 16).padding(.bottom, 154)
                }
                if selected != nil, let item {
                    Color.black
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            Button {
                                page(-1)
                            } label: {
                                Image(systemName: "chevron.left").frame(width: 44, height: 44)
                            }
                            .disabled(index == 0).accessibilityLabel("上一张")
                            Spacer(minLength: 0)
                            Button(item.status == "saved" ? "已保存" : "保存") { controls.savePhoto(item.id) }
                                .disabled(camera.photoBusy || camera.controlBusy || item.status == "saved")
                            Button(item.status == "ignored" ? "已忽略" : "忽略") { controls.ignorePhoto(item.id) }
                                .disabled(camera.photoBusy || camera.controlBusy || item.status != "pending")
                            Spacer(minLength: 0)
                            Button {
                                page(1)
                            } label: {
                                Image(systemName: "chevron.right").frame(width: 44, height: 44)
                            }
                            .disabled(index == ids.count - 1).accessibilityLabel("下一张")
                        }.font(.subheadline).buttonStyle(.plain)
                        HStack {
                            Text("\(index + 1) / \(ids.count) · \(item.id)").monospacedDigit()
                            Spacer()
                            Button("返回拍摄") { selected = nil }
                        }.font(.caption)
                        ZStack {
                            if let image = pages[item.id] {
                                CameraZoomImage(image: image, page: page).id(item.id)
                            } else if failure == nil {
                                ProgressView().tint(.white)
                            }
                            if let failure { Text(failure).font(.caption).padding().background(.black.opacity(0.7)) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if let message = camera.photoMessage { Text(message).font(.caption).padding(8) }
                    }.padding(12).transition(.opacity).accessibilityIdentifier("camera.gallery.browser")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).foregroundStyle(.white)
                .onChange(of: ids) { _, values in
                    self.selected = CameraGalleryNavigation.retainedSelection(selected, in: values)
                }
                .onChange(of: camera.gallerySession) { _, _ in
                    selected = nil
                    pages.removeAll()
                    thumbnails.removeAll()
                }
                .task(id: (camera.gallerySession ?? "") + ids.joined(separator: ",") + (selected ?? "")) {
                    guard let scope = camera.gallerySession else {
                        thumbnails.removeAll()
                        pages.removeAll()
                        return
                    }
                    let stack = Array(ids.suffix(3))
                    let visible =
                        (selected == nil || ids.isEmpty)
                        ? [] : Array(ids[max(0, index - 1)...min(ids.count - 1, index + 1)])
                    thumbnails = thumbnails.filter { stack.contains($0.key) }
                    pages = pages.filter { visible.contains($0.key) }
                    failure = nil
                    do {
                        for id in Array(Set(stack + visible)).sorted() {
                            try Task.checkCancellation()
                            if (!stack.contains(id) || thumbnails[id] != nil)
                                && (!visible.contains(id) || pages[id] != nil)
                            {
                                continue
                            }
                            let data = try await controls.previewImage(id, session: scope)
                            try Task.checkCancellation()
                            guard scope == camera.gallerySession, ids.contains(id) else { return }
                            if stack.contains(id), thumbnails[id] == nil {
                                thumbnails[id] = try thumbnail(data, dimension: 256)
                            }
                            if visible.contains(id), pages[id] == nil {
                                pages[id] = try thumbnail(data, dimension: 2048)
                            }
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        failure = "读取预览失败：" + error.localizedDescription
                    }
                }
        }
        private func page(_ delta: Int) {
            guard let next = CameraGalleryNavigation.moved(selected, by: delta, in: ids) else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { selected = next }
        }
        private func thumbnail(_ data: Data, dimension: Int) throws -> UIImage {
            guard let original = UIImage(data: data),
                let image = original.preparingThumbnail(of: CGSize(width: dimension, height: dimension))
            else { throw UIRequestError.unavailable }
            return image
        }

    }

    @MainActor struct CapturedPhotoView: View {
        @Bindable var photo: CapturedPhotoPresentation
        @State private var small = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            GeometryReader { geometry in
                Image(uiImage: photo.image).resizable().scaledToFit()
                    .frame(width: small ? 72 : geometry.size.width, height: small ? 94 : geometry.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: small ? 10 : 0))
                    .position(
                        x: small ? geometry.size.width - 56 : geometry.size.width / 2,
                        y: small ? geometry.size.height - 210 : geometry.size.height / 2
                    )
                    .allowsHitTesting(false)
                    .onAppear {
                        withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.35), completionCriteria: .removed) {
                            small = true
                        } completion: {
                            photo.finish(reachedThumbnail: true)
                        }
                    }
                    .onDisappear { photo.finish() }
            }.allowsHitTesting(false)
        }
    }

    @MainActor private struct CameraZoomImage: UIViewRepresentable {
        let image: UIImage
        let page: (Int) -> Void
        func makeCoordinator() -> Coordinator { Coordinator(page: page) }
        func makeUIView(context: Context) -> UIScrollView {
            let scroll = ZoomScroll()
            scroll.delegate = context.coordinator
            scroll.minimumZoomScale = 1
            scroll.maximumZoomScale = CameraGalleryNavigation.maximumZoom
            scroll.bouncesZoom = true
            scroll.showsHorizontalScrollIndicator = false
            scroll.showsVerticalScrollIndicator = false
            scroll.image.image = image
            scroll.addSubview(scroll.image)
            context.coordinator.scroll = scroll
            let doubleTap = UITapGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            scroll.addGestureRecognizer(doubleTap)
            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = UISwipeGestureRecognizer(
                    target: context.coordinator, action: #selector(Coordinator.swipe(_:)))
                swipe.direction = direction
                swipe.delegate = context.coordinator
                scroll.addGestureRecognizer(swipe)
            }
            scroll.panGestureRecognizer.isEnabled = false
            return scroll
        }
        func updateUIView(_ uiView: UIScrollView, context: Context) { context.coordinator.page = page }
        final class ZoomScroll: UIScrollView {
            let image = UIImageView()
            private var previous = CGSize.zero
            override func layoutSubviews() {
                super.layoutSubviews()
                guard bounds.size != previous else { return }
                previous = bounds.size
                setZoomScale(1, animated: false)
                image.frame = CGRect(origin: .zero, size: bounds.size)
                image.contentMode = .scaleAspectFit
                contentSize = bounds.size
            }
        }
        final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
            weak var scroll: ZoomScroll?
            var page: (Int) -> Void
            init(page: @escaping (Int) -> Void) { self.page = page }
            func viewForZooming(in scrollView: UIScrollView) -> UIView? { scroll?.image }
            func scrollViewDidZoom(_ scrollView: UIScrollView) {
                scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > 1.01
            }
            func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                !(gestureRecognizer is UISwipeGestureRecognizer) || (scroll?.zoomScale ?? 1) <= 1.01
            }
            @objc func swipe(_ gesture: UISwipeGestureRecognizer) { page(gesture.direction == .left ? 1 : -1) }
            @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
                guard let scroll else { return }
                if scroll.zoomScale > 1.01 {
                    scroll.setZoomScale(1, animated: true)
                } else {
                    let point = gesture.location(in: scroll.image)
                    scroll.zoom(
                        to: CGRect(
                            x: point.x - scroll.bounds.width / 4, y: point.y - scroll.bounds.height / 4,
                            width: scroll.bounds.width / 2, height: scroll.bounds.height / 2), animated: true)
                }
            }
        }
    }
#endif
