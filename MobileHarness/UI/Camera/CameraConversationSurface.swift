#if os(iOS)
    import SwiftUI
    import UIKit

    /// Independent background visual surface; photo content stays in the window host.
    @MainActor
    public struct CameraConversationSurface<Content: View>: View {
        let camera: CameraState
        let controls: any CameraControlling
        let blocksNewActions: Bool
        let openSettings: () -> Void
        @ViewBuilder let content: () -> Content
        public init(
            camera: CameraState, controls: any CameraControlling, blocksNewActions: Bool = false,
            openSettings: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content
        ) {
            self.camera = camera
            self.controls = controls
            self.blocksNewActions = blocksNewActions
            self.openSettings = openSettings
            self.content = content
        }
        public var body: some View {
            ZStack {
                Color.black.ignoresSafeArea()
                if camera.perceptionEnabled && camera.isVisible && camera.faceVisible
                    && (camera.windows?.hasVisibleBackground() ?? true)
                {
                    CameraFrameView(state: camera).ignoresSafeArea().opacity(0.30)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                content().environment(\.eyeGaze, camera.displayGaze)
            }
            .overlay(alignment: .topTrailing) {
                CameraControlsOverlay(
                    camera: camera, controls: controls, blocksNewActions: blocksNewActions, openSettings: openSettings)
            }
            .overlay(alignment: .topLeading) { CameraStatisticsOverlay(camera: camera) }
            .preferredColorScheme(.dark)
        }
    }

    @MainActor
    private struct CameraControlsOverlay: View {
        let camera: CameraState
        let controls: any CameraControlling
        let blocksNewActions: Bool
        let openSettings: () -> Void
        @Environment(\.openURL) private var openURL
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            VStack(alignment: .trailing, spacing: 12) {
                HStack(spacing: 12) {
                    Button(action: controls.togglePerception) {
                        Image(systemName: camera.perceptionEnabled ? "eye.fill" : "eye")
                            .frame(width: 48, height: 48)
                    }
                    .accessibilityLabel(camera.perceptionEnabled ? "关闭视觉" : "打开视觉")
                    .accessibilityValue(camera.perceptionEnabled ? (camera.isVisible ? "已开启" : "等待相机") : "已关闭")
                    .accessibilityIdentifier("camera.toggle")
                    .disabled(camera.isBusy || camera.controlBusy || (blocksNewActions && !camera.perceptionEnabled))
                    if camera.perceptionEnabled {
                        HStack(spacing: 12) {
                            Button(action: controls.switchPerceptionCamera) {
                                Image(systemName: "arrow.triangle.2.circlepath.camera")
                                    .frame(width: 48, height: 48)
                            }
                            .disabled(!camera.canSwitch(.perception))
                            .accessibilityLabel(camera.facing == .front ? "切换到后置摄像头" : "切换到前置摄像头")
                            .accessibilityIdentifier("camera.switch")
                        }
                        .font(.system(size: 18, weight: .medium))
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                    }
                    Button(action: openSettings) {
                        Image(systemName: "gearshape").frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("设置")
                    .accessibilityIdentifier("app.settings")
                }
                .font(.system(size: 20, weight: .medium))
                .buttonStyle(.plain)
                .background(.black.opacity(0.4), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                if let message = camera.controlMessage ?? camera.message ?? camera.visionMessage,
                    camera.perceptionEnabled
                {
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(message).font(.footnote)
                            .multilineTextAlignment(.trailing)
                        if camera.needsSettings {
                            Button("打开设置") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        } else {
                            Button("重试", action: controls.retryPerception).disabled(
                                blocksNewActions || camera.isBusy || camera.controlBusy)
                        }
                    }
                    .font(.footnote.weight(.medium))
                    .padding(12)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: 260, alignment: .trailing)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: camera.perceptionEnabled)
        }
    }
    @MainActor
    private struct CameraStatisticsOverlay: View {
        let camera: CameraState
        @State private var statisticsExpanded = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            if camera.perceptionEnabled, camera.isVisible, camera.faceVisible,
                let statistics = camera.skeleton?.statistics
            {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            statisticsExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("YOLO · \(metric(statistics.framesPerSecond, suffix: "FPS"))")
                                .fontWeight(.semibold)
                            Image(systemName: statisticsExpanded ? "chevron.up" : "chevron.down")
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(statisticsExpanded ? "收起性能数据" : "展开性能数据")
                    .accessibilityValue(statisticsExpanded ? "已展开" : "已收起")
                    .accessibilityIdentifier("camera.poseStatistics.toggle")
                    if statisticsExpanded {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("间隔 \(metric(statistics.detectionIntervalMilliseconds, suffix: "ms"))")
                            Text("画面运动 \(statistics.imageMotion.map { String(format: "%.2f", $0) } ?? "—")")
                            Text("等待 \(metric(statistics.queueMilliseconds, suffix: "ms"))")
                            Text("推理 \(metric(statistics.inferenceMilliseconds, suffix: "ms"))")
                            Text("总延迟 \(metric(statistics.totalMilliseconds, suffix: "ms"))")
                            Text("跳过 \(statistics.replacements) 帧")
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                        .allowsHitTesting(false)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                .padding(.leading, 20)
                .padding(.top, 8)
                .accessibilityIdentifier("camera.poseStatistics")
            }
        }
        private func metric(_ value: Double?, suffix: String) -> String {
            guard let value else { return "— \(suffix)" }
            return String(format: "%.1f %@", value, suffix)
        }
    }

    @MainActor public struct CameraWindowContent<Preview: View>: View {
        let camera: CameraState
        let controls: any CameraControlling
        let rendersPreview: Bool
        let preview: () -> Preview
        @Environment(\.openURL) private var openURL
        public init(
            camera: CameraState, controls: any CameraControlling, rendersPreview: Bool,
            @ViewBuilder preview: @escaping () -> Preview
        ) {
            self.camera = camera
            self.controls = controls
            self.rendersPreview = rendersPreview
            self.preview = preview
        }
        public var body: some View {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if rendersPreview && camera.isEnabled && camera.isVisible {
                        preview().aspectRatio(camera.photoAspect, contentMode: .fit).allowsHitTesting(false)
                    }
                    if let photo = camera.capturedPhoto {
                        CapturedPhotoView(photo: photo, camera: camera, controls: controls).id(photo.id)
                    }
                    if camera.isBusy { ProgressView().tint(.white) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .overlay(alignment: .top) {
                        if let message = camera.controlMessage ?? camera.photoRendererFailure ?? camera.message {
                            Text(message).font(.caption).multilineTextAlignment(.center).padding(8).background(
                                .black.opacity(0.6))
                        }
                    }
                HStack(spacing: 24) {
                    Button(action: controls.switchCamera) {
                        Image(systemName: "arrow.triangle.2.circlepath.camera").frame(width: 48, height: 48)
                    }.accessibilityLabel("切换镜头").disabled(!camera.canSwitchCamera)
                    if camera.isEnabled && camera.isVisible {
                        Button(action: controls.takePhoto) {
                            Circle().fill(.white).frame(width: 54, height: 54).padding(5)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }.accessibilityLabel("拍照").accessibilityIdentifier("camera.capture")
                            .disabled(camera.controlBusy || camera.photoBusy || camera.isBusy)
                    } else if camera.needsSettings {
                        Button("打开系统设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    } else {
                        Button("开启相机", action: controls.open).frame(minHeight: 44)
                            .disabled(camera.controlBusy || camera.isBusy)
                    }
                    Text("照片").font(.subheadline).frame(width: 48)
                }.buttonStyle(.plain).padding(16)
            }.foregroundStyle(.white).background(.black)
        }
    }
#endif
