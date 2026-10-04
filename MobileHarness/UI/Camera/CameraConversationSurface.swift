#if os(iOS)
    import SwiftUI
    import UIKit

    /// Camera is always behind content; preview and dimming layer never intercept touches.
    @MainActor
    public struct CameraConversationSurface<Content: View, Preview: View>: View {
        @Bindable var camera: CameraState
        let controls: any CameraControlling
        let preview: () -> Preview
        @Environment(\.openURL) private var openURL
        let openSettings: () -> Void
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @ViewBuilder let content: () -> Content

        public init(
            camera: CameraState, controls: any CameraControlling, openSettings: @escaping () -> Void,
            @ViewBuilder preview: @escaping () -> Preview, @ViewBuilder content: @escaping () -> Content
        ) {
            self.camera = camera
            self.controls = controls
            self.openSettings = openSettings
            self.preview = preview
            self.content = content
        }

        public var body: some View {
            ZStack {
                Color.black.ignoresSafeArea()
                preview()
                    .ignoresSafeArea()
                    .opacity(camera.isVisible ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                content().environment(\.eyeGaze, camera.gaze)
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 12) {
                    HStack(spacing: 12) {
                        Button(action: controls.toggle) {
                            Image(systemName: camera.isEnabled ? "video.fill" : "video.slash.fill")
                                .frame(width: 48, height: 48)
                        }
                        .accessibilityLabel(camera.isEnabled ? "关闭摄像头" : "开启摄像头")
                        .accessibilityValue(camera.isVisible ? "已开启" : (camera.isEnabled ? "等待相机" : "已关闭"))
                        .accessibilityIdentifier("camera.toggle")
                        if camera.isEnabled {
                            HStack(spacing: 12) {
                                Button(action: controls.switchCamera) {
                                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                                        .frame(width: 48, height: 48)
                                }
                                .disabled(!camera.isEnabled || camera.isBusy)
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
                    if let message = camera.message ?? camera.visionMessage ?? camera.trackingMessage, camera.isEnabled
                    {
                        VStack(alignment: .trailing, spacing: 8) {
                            Text(message).font(.footnote)
                                .multilineTextAlignment(.trailing)
                            if camera.needsSettings {
                                Button("打开设置") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                                }
                            } else {
                                Button("重试", action: controls.retry).disabled(camera.isBusy)
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
            .overlay(alignment: .topLeading) {
                if camera.isVisible, let statistics = camera.skeleton?.statistics {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("YOLO · \(metric(statistics.framesPerSecond, suffix: "FPS"))")
                            .fontWeight(.semibold)
                        Text("间隔 \(metric(statistics.detectionIntervalMilliseconds, suffix: "ms"))")
                        Text("画面运动 \(statistics.imageMotion.map { String(format: "%.2f", $0) } ?? "—")")
                        Text("等待 \(metric(statistics.queueMilliseconds, suffix: "ms"))")
                        Text("推理 \(metric(statistics.inferenceMilliseconds, suffix: "ms"))")
                        Text("总延迟 \(metric(statistics.totalMilliseconds, suffix: "ms"))")
                        Text("替换 \(statistics.replacements) 帧")
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.leading, 12)
                    .padding(.top, 68)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("camera.poseStatistics")
                }
            }
            .preferredColorScheme(.dark)

        }
        private func metric(_ value: Double?, suffix: String) -> String {
            guard let value else { return "— \(suffix)" }
            return String(format: "%.1f %@", value, suffix)
        }
    }

#endif
