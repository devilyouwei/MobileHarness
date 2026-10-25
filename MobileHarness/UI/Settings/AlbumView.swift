#if os(iOS)
    import CoreTransferable
    import PhotosUI
    import ImageIO
    import SwiftUI
    import UniformTypeIdentifiers

    /// Selector-owned file URLs are read only inside the transfer callback, never persisted as media references.
    private struct AlbumPickedFile: Transferable, Sendable {
        let data: Data
        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(importedContentType: .image) { file in
                let handle = try FileHandle(forReadingFrom: file.file)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 32 * 1024 * 1024 + 1) ?? Data()
                guard !data.isEmpty, data.count <= 32 * 1024 * 1024 else { throw AlbumSelectionError.tooLarge }
                return AlbumPickedFile(data: data)
            }
        }
    }
    private enum AlbumSelectionError: Error, LocalizedError {
        case tooLarge, unavailable
        var errorDescription: String? {
            switch self {
            case .tooLarge: "照片超过 32 MiB 限制"
            case .unavailable: "无法读取所选照片"
            }
        }
    }
    @MainActor public struct AlbumView: View {
        @Bindable private var album: UIAlbumContainer
        @State private var showsPicker = false
        @State private var selection: [PhotosPickerItem] = []
        @State private var selected: AlbumPhoto?
        public init(album: UIAlbumContainer) { self.album = album }
        public var body: some View {
            ScrollView {
                if !album.hasLoaded, album.loading { ProgressView().padding() }
                if album.hasLoaded, album.items.isEmpty {
                    ContentUnavailableView(
                        "相册暂无照片", systemImage: "photo.on.rectangle",
                        description: Text("拍照后保存到 App 相册，或导入手机中的照片。Live Photo 仅导入静态照片。"))
                }
                if let message = album.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary).padding()
                        .accessibilityIdentifier("album.status")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 3)], spacing: 3) {
                    ForEach(album.items) { photo in
                        Button {
                            selected = photo
                        } label: {
                            AlbumThumbnail(album: album, photo: photo)
                        }.buttonStyle(.plain).accessibilityLabel("照片，" + photo.date.formatted())
                    }
                }.padding(.horizontal, 3)
                if album.next != nil {
                    Button("加载更多") { Task { await album.loadMore() } }.disabled(album.loading).padding()
                }
                if !album.hasLoaded, !album.loading {
                    Button("重新加载") { Task { await album.loadMore(reset: true) } }.padding()
                }
            }
            .navigationTitle("相册").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("导入", systemImage: "plus") { showsPicker = true }
                    .disabled(album.busy).accessibilityIdentifier("album.import")
            }
            .photosPicker(
                isPresented: $showsPicker, selection: $selection, maxSelectionCount: 20,
                matching: .images, preferredItemEncoding: .current
            )
            .navigationContext(
                .album, content: album.contextSnapshot().content,
                overlay: showsPicker ? .photoPicker : nil
            )
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    if album.busy { ProgressView("正在处理…") }
                    Text("支持 JPEG、HEIC、PNG；Live Photo 仅导入静态照片")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(8).background(.bar)
            }
            .task { await album.loadMore(reset: true) }
            .refreshable { await album.loadMore(reset: true) }
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                let sources = items.map { item in
                    AlbumImportSource {
                        guard let value = try await item.loadTransferable(type: AlbumPickedFile.self) else {
                            throw AlbumSelectionError.unavailable
                        }
                        return value.data
                    }
                }
                selection = []
                album.importPhotos(sources)
            }
            .navigationDestination(item: $selected) { photo in
                AlbumDetailView(album: album, photo: photo)
            }
        }
    }
    @MainActor private struct AlbumThumbnail: View {
        let album: UIAlbumContainer
        let photo: AlbumPhoto
        @State private var image: UIImage?
        @State private var failed = false
        var body: some View {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failed {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(height: 115).frame(maxWidth: .infinity).clipped()
            .task(id: photo.id) {
                do {
                    let data = try await album.image(photo.id, thumbnail: true)
                    try Task.checkCancellation()
                    guard let value = UIImage(data: data) else { throw AlbumSelectionError.unavailable }
                    image = value
                } catch is CancellationError {} catch { failed = true }
            }
            .onDisappear { image = nil }
        }
    }
    @MainActor private struct AlbumDetailView: View {
        let album: UIAlbumContainer
        let photo: AlbumPhoto
        @Environment(\.dismiss) private var dismiss
        @State private var data: Data?
        @State private var error: String?
        @State private var confirmingDelete = false
        var body: some View {
            VStack(spacing: 12) {
                if let data {
                    AlbumZoomImage(data: data)
                } else if let error {
                    ContentUnavailableView("照片不可用", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text(photo.date.formatted()).font(.caption).foregroundStyle(.secondary)
                if let message = album.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
                HStack {
                    Button("保存到手机相册", systemImage: "square.and.arrow.down") { album.export(photo.id) }
                        .disabled(album.busy || data == nil).accessibilityIdentifier("album.export")
                    Spacer()
                    Button("删除", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                        .disabled(album.busy).accessibilityIdentifier("album.delete")
                }.padding()
            }
            .navigationContext(
                .albumPhoto, itemID: photo.id,
                content: data != nil ? .ready : error != nil ? .failed : .loading,
                overlay: confirmingDelete ? .deleteConfirmation : nil
            )
            .navigationTitle("照片").navigationBarTitleDisplayMode(.inline)
            .task(id: photo.id) {
                album.clearMessage()
                do { data = try await album.image(photo.id, thumbnail: false) } catch is CancellationError {} catch {
                    self.error = error.localizedDescription
                }
            }
            .confirmationDialog("从 App 相册删除这张照片？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除照片", role: .destructive) { album.delete(photo.id) }
            } message: {
                Text("仅删除 App 内照片，不影响手机相册中的副本。关联聊天中的原图将不可用。")
            }
            .onChange(of: album.items) { _, values in
                if album.hasLoaded, !values.contains(where: { $0.id == photo.id }), !album.busy { dismiss() }
            }
            .onChange(of: album.busy) { _, busy in
                if !busy, !album.items.contains(where: { $0.id == photo.id }) { dismiss() }
            }
        }
    }
    private struct AlbumZoomImage: UIViewRepresentable {
        let data: Data
        func makeCoordinator() -> Coordinator { Coordinator() }
        func makeUIView(context: Context) -> UIScrollView {
            let scroll = UIScrollView()
            scroll.minimumZoomScale = 1
            scroll.maximumZoomScale = 5
            scroll.delegate = context.coordinator
            scroll.contentInsetAdjustmentBehavior = .never
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceShouldCacheImmediately: false,
            ]
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            let decoded = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
            guard let decoded else {
                let label = UILabel(frame: scroll.bounds)
                label.text = "无法解码照片，请返回后重试"
                label.textAlignment = .center
                label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                scroll.addSubview(label)
                return scroll
            }
            let image = UIImageView(image: UIImage(cgImage: decoded))
            image.contentMode = .scaleAspectFit
            image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            image.frame = scroll.bounds
            scroll.addSubview(image)
            context.coordinator.image = image
            return scroll
        }
        func updateUIView(_ view: UIScrollView, context: Context) {}
        final class Coordinator: NSObject, UIScrollViewDelegate {
            weak var image: UIImageView?
            func viewForZooming(in scrollView: UIScrollView) -> UIView? { image }
        }
    }
#endif
