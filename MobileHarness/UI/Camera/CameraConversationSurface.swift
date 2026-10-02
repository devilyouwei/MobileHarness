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
                                Menu {
                                    Picker(
                                        "灰度变化阈值",
                                        selection: Binding(
                                            get: { camera.changeThreshold }, set: controls.setChangeThreshold)
                                    ) {
                                        Text("1%").tag(0.01)
                                        Text("3%（默认）").tag(0.03)
                                        Text("5%").tag(0.05)
                                        Text("10%").tag(0.10)
                                    }
                                } label: {
                                    Text("\(Int(camera.changeThreshold * 100))%")
                                        .font(.system(size: 15, weight: .medium).monospacedDigit())
                                        .frame(width: 48, height: 48)
                                }
                                .accessibilityLabel("识别抽帧阈值")
                                .accessibilityValue("\(Int(camera.changeThreshold * 100))%")
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
                    if let message = camera.message ?? camera.visionMessage, camera.isEnabled {
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
            .preferredColorScheme(.dark)

        }
    }

#endif
