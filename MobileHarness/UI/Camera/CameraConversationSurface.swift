#if os(iOS)
    import SwiftUI
    import UIKit

    /// Camera is always behind content; preview and dimming layer never intercept touches.
    @MainActor
    public struct CameraConversationSurface<Content: View, Preview: View>: View {
        let camera: CameraState
        let controls: any CameraControlling
        let blocksNewActions: Bool
        let preview: () -> Preview
        let openSettings: () -> Void
        @ViewBuilder let content: () -> Content

        public init(
            camera: CameraState, controls: any CameraControlling, blocksNewActions: Bool = false,
            openSettings: @escaping () -> Void,
            @ViewBuilder preview: @escaping () -> Preview, @ViewBuilder content: @escaping () -> Content
        ) {
            self.blocksNewActions = blocksNewActions
            self.camera = camera
            self.controls = controls
            self.openSettings = openSettings
            self.preview = preview
            self.content = content
        }

        public var body: some View {
            ZStack {
                Color.black.ignoresSafeArea()
                CameraBackground(camera: camera, preview: preview)
                Color.black.opacity(0.42).ignoresSafeArea().allowsHitTesting(false)
                CameraGazeContent(camera: camera, content: content)
            }
            .overlay(alignment: .topTrailing) {
                CameraControlsOverlay(
                    camera: camera, controls: controls, blocksNewActions: blocksNewActions, openSettings: openSettings)
            }
            .overlay(alignment: .topLeading) { CameraStatisticsOverlay(camera: camera) }
            .overlay { CameraPhotoOverlay(camera: camera, controls: controls) }
            .preferredColorScheme(.dark)
        }
    }

    @MainActor
    private struct CameraBackground<Preview: View>: View {
        let camera: CameraState
        let preview: () -> Preview
        var body: some View {
            preview().ignoresSafeArea().opacity(camera.isVisible ? 1 : 0)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    @MainActor
    private struct CameraGazeContent<Content: View>: View {
        let camera: CameraState
        let content: () -> Content
        var body: some View { content().environment(\.eyeGaze, camera.displayGaze) }
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
                    Button(action: controls.toggle) {
                        Image(systemName: camera.isEnabled ? "video.fill" : "video.slash.fill")
                            .frame(width: 48, height: 48)
                    }
                    .accessibilityLabel(camera.isEnabled ? "关闭摄像头" : "开启摄像头")
                    .accessibilityValue(camera.isVisible ? "已开启" : (camera.isEnabled ? "等待相机" : "已关闭"))
                    .accessibilityIdentifier("camera.toggle")
                    .disabled(camera.isBusy || camera.controlBusy || (blocksNewActions && !camera.isEnabled))
                    if camera.isEnabled {
                        HStack(spacing: 12) {
                            Button(action: controls.switchCamera) {
                                Image(systemName: "arrow.triangle.2.circlepath.camera")
                                    .frame(width: 48, height: 48)
                            }
                            .disabled(!camera.canSwitchCamera)
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
                if let message = camera.controlMessage ?? camera.message ?? camera.visionMessage, camera.isEnabled {
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(message).font(.footnote)
                            .multilineTextAlignment(.trailing)
                        if camera.needsSettings {
                            Button("打开设置") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        } else {
                            Button("重试", action: controls.retry).disabled(
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
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: camera.isEnabled)
        }
    }
    @MainActor
    private struct CameraStatisticsOverlay: View {
        let camera: CameraState
        @State private var statisticsExpanded = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            if camera.isVisible, let statistics = camera.skeleton?.statistics {
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
    @MainActor
    private struct CameraPhotoOverlay: View {
        let camera: CameraState
        let controls: any CameraControlling
        var body: some View {
            if let photo = camera.capturedPhoto {
                CapturedPhotoView(photo: photo, camera: camera, controls: controls).id(photo.id).ignoresSafeArea()
            }
        }
    }
#endif
