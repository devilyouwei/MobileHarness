#if os(iOS)
    import SwiftUI
    import UIKit

    /// One image and one bounded presentation transaction; no device or storage ownership.
    @MainActor @Observable public final class CapturedPhotoPresentation {
        public let id: UUID
        public let image: UIImage
        public var isThumbnail = false
        public var opacity = 0.0
        public private(set) var didReachThumbnail = false
        private let completed: @MainActor (Bool) -> Void
        private var acknowledged = false
        public init(id: UUID, image: UIImage, completed: @escaping @MainActor (Bool) -> Void) {
            self.id = id
            self.image = image
            self.completed = completed
        }
        public func finish(reachedThumbnail: Bool = false) {
            guard !acknowledged else { return }
            acknowledged = true
            didReachThumbnail = reachedThumbnail
            completed(reachedThumbnail)
        }
    }

    @MainActor struct CapturedPhotoView: View {
        @Bindable var photo: CapturedPhotoPresentation
        @Bindable var camera: CameraState
        let controls: any CameraControlling
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var inspecting = false
        var body: some View {
            GeometryReader { geometry in
                let small = photo.isThumbnail
                Image(uiImage: photo.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: small ? 96 : geometry.size.width, height: small ? 128 : geometry.size.height)
                    .background(small ? Color.black : Color.black.opacity(0.94))
                    .clipShape(RoundedRectangle(cornerRadius: small ? 12 : 0))
                    .overlay(
                        RoundedRectangle(cornerRadius: small ? 12 : 0).stroke(
                            .white.opacity(small ? 0.85 : 0), lineWidth: 2)
                    )
                    .shadow(radius: small ? 8 : 0)
                    .opacity(photo.opacity)
                    .position(
                        x: small ? max(48, geometry.size.width - 68) : geometry.size.width / 2,
                        y: small
                            ? max(64, geometry.size.height - geometry.safeAreaInsets.bottom - 84)
                            : geometry.size.height / 2
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                if photo.didReachThumbnail {
                    ZStack {
                        Button {
                            inspecting = true
                        } label: {
                            Color.clear.frame(width: 96, height: 128)
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .accessibilityLabel("查看刚拍摄的照片")
                        .accessibilityIdentifier("camera.photo.inspect")
                        VStack(spacing: 0) {
                            HStack {
                                Spacer(minLength: 0)
                                Button {
                                    controls.ignorePhoto(photo.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .frame(width: 44, height: 44)
                                        .background(.black.opacity(0.65), in: Circle())
                                        .contentShape(Circle())
                                }
                                .accessibilityLabel("忽略照片，关闭缩略图")
                                .accessibilityIdentifier("camera.photo.ignore")
                                .disabled(camera.photoBusy)
                            }
                            Spacer(minLength: 0)
                            Button {
                                controls.savePhoto(photo.id)
                            } label: {
                                Label(
                                    camera.savedPhotoID == photo.id ? "已保存" : "保存", systemImage: "square.and.arrow.down"
                                )
                                .font(.caption).frame(width: 96, height: 44)
                                .background(.black.opacity(0.65))
                                .contentShape(Rectangle())
                            }
                            .accessibilityLabel("保存照片到系统相册")
                            .accessibilityIdentifier("camera.photo.save")
                            .disabled(camera.photoBusy || camera.savedPhotoID == photo.id)
                        }
                    }
                    .frame(width: 96, height: 128)
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .position(
                        x: max(48, geometry.size.width - 68),
                        y: max(64, geometry.size.height - geometry.safeAreaInsets.bottom - 84))
                    if let message = camera.photoMessage {
                        Text(message).font(.caption).foregroundStyle(.white)
                            .padding(8).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                            .frame(width: min(geometry.size.width - 40, 280))
                            .position(
                                x: geometry.size.width / 2,
                                y: max(24, geometry.size.height - geometry.safeAreaInsets.bottom - 180)
                            )
                            .allowsHitTesting(false)
                    }
                }
            }
            .task(id: photo.id) {
                withAnimation(.easeOut(duration: 0.15)) { photo.opacity = 1 }
                do { try await Task.sleep(for: .milliseconds(400)) } catch {
                    photo.finish()
                    return
                }
                if reduceMotion {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { photo.isThumbnail = true }
                    photo.finish(reachedThumbnail: true)
                } else {
                    withAnimation(.easeInOut(duration: 0.45), completionCriteria: .removed) {
                        photo.isThumbnail = true
                    } completion: {
                        photo.finish(reachedThumbnail: true)
                    }
                }
            }
            .onDisappear { photo.finish() }
            .onChange(of: camera.capturedPhoto?.id) { _, id in
                if id != photo.id { inspecting = false }
            }
            .fullScreenCover(isPresented: $inspecting) {
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: photo.image).resizable().scaledToFit()
                    HStack(spacing: 20) {
                        Button("保存到相册") { controls.savePhoto(photo.id) }
                            .disabled(camera.photoBusy || camera.savedPhotoID == photo.id)
                        Button("忽略") { controls.ignorePhoto(photo.id) }
                            .disabled(camera.photoBusy)
                        Button("返回") { inspecting = false }
                    }.padding(20)
                    VStack {
                        Spacer()
                        if let message = camera.photoMessage { Text(message).padding(20) }
                    }.allowsHitTesting(false)
                }.foregroundStyle(.white)
            }
        }
    }
#endif
