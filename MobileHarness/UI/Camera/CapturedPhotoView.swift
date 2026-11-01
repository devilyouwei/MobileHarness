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
        public internal(set) var isThumbnail = false
        public internal(set) var opacity = 0.0
        public private(set) var didReachThumbnail = false
        public let departure = PhotoDeparture()
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
            didReachThumbnail = reachedThumbnail
            completed(reachedThumbnail)
        }
    }

    @MainActor
    struct CapturedPhotoView: View {
        @Bindable var photo: CapturedPhotoPresentation
        @Bindable var camera: CameraState
        let controls: any CameraControlling
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.scenePhase) private var scenePhase
        @State private var inspecting = false
        @State private var inspectorVisible = false
        @State private var animatedDepartureID: String?
        @State private var departureKind: PhotoDeparture.Kind?
        @State private var departurePhase: PhotoDeparturePhase = .resting
        @State private var departureOpacity = 1.0
        var body: some View {
            GeometryReader { geometry in
                let small = photo.isThumbnail
                let departure = PhotoDepartureLayout.pose(
                    size: geometry.size, bottomInset: geometry.safeAreaInsets.bottom,
                    kind: departureKind, phase: departurePhase)
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
                    .opacity(photo.opacity * departureOpacity)
                    .scaleEffect(departure.scale)
                    .position(
                        x: small ? departure.center.x : geometry.size.width / 2,
                        y: small ? departure.center.y : geometry.size.height / 2
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                if photo.didReachThumbnail, departureKind == nil {
                    ZStack {
                        Button {
                            inspectorVisible = true
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
                                    camera.savedMediaID == photo.id ? "已保存" : "保存", systemImage: "square.and.arrow.down"
                                )
                                .font(.caption).frame(width: 96, height: 44)
                                .background(.black.opacity(0.65))
                                .contentShape(Rectangle())
                            }
                            .accessibilityLabel("保存照片到 App 相册")
                            .accessibilityIdentifier("camera.photo.save")
                            .disabled(camera.photoBusy || camera.savedMediaID == photo.id)
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
                guard !photo.didReachThumbnail else { return }
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
            .onAppear { photo.departure.setAvailable(scenePhase == .active) }
            .onDisappear {
                photo.finish()
                if !inspectorVisible { photo.departure.setAvailable(false) }
            }
            .onChange(of: scenePhase) { _, phase in photo.departure.setAvailable(phase == .active) }
            .onChange(of: photo.departure.request) { _, request in
                guard let request else { return }
                departureKind = request.kind
                if inspectorVisible {
                    inspecting = false
                } else {
                    animateDeparture(request)
                }
            }
            .onChange(of: camera.capturedPhoto?.id) { _, id in
                if id != photo.id { inspecting = false }
            }
            .onChange(of: inspecting) { _, visible in
                if !visible {
                    inspectorVisible = false
                    if let request = photo.departure.request { animateDeparture(request) }
                }
            }
            .overlay {
                if inspecting {
                    ZStack(alignment: .topTrailing) {
                        Color.black.ignoresSafeArea()
                        Image(uiImage: photo.image).resizable().scaledToFit()
                        HStack(spacing: 20) {
                            Button("保存到 App 相册") {
                                inspecting = false
                                controls.savePhoto(photo.id)
                            }
                            .disabled(camera.photoBusy || camera.savedMediaID == photo.id)
                            Button("忽略") {
                                inspecting = false
                                controls.ignorePhoto(photo.id)
                            }
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

        private func animateDeparture(_ request: PhotoDeparture.Request) {
            guard photo.departure.request?.id == request.id, animatedDepartureID != request.id else { return }
            animatedDepartureID = request.id
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.2), completionCriteria: .removed) {
                    departureOpacity = 0
                } completion: {
                    photo.departure.complete(id: request.id, success: true)
                }
            } else if request.kind == .save {
                withAnimation(.easeOut(duration: 0.18), completionCriteria: .removed) {
                    departurePhase = .enlarged
                } completion: {
                    guard photo.departure.request?.id == request.id else { return }
                    withAnimation(.timingCurve(0.25, 0, 0.65, 1, duration: 0.42), completionCriteria: .removed) {
                        departurePhase = .exited
                    } completion: {
                        photo.departure.complete(id: request.id, success: true)
                    }
                }
            } else {
                withAnimation(.timingCurve(0.34, 0, 0.68, 1, duration: 0.52), completionCriteria: .removed) {
                    departurePhase = .exited
                } completion: {
                    photo.departure.complete(id: request.id, success: true)
                }
            }
        }
    }
#endif
