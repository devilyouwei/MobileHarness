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
                    if rendersPreview && camera.isEnabled && camera.isVisible && camera.recordedVideo == nil {
                        preview().aspectRatio(camera.photoAspect, contentMode: .fit).allowsHitTesting(false)
                    }
                    if let photo = camera.capturedPhoto {
                        CapturedPhotoView(photo: photo, camera: camera, controls: controls).id(photo.id)
                    }
                    if let video = camera.recordedVideo, rendersPreview {
                        LocalVideoPlayer(file: video.file)
                    }
                    if let count = camera.countdown {
                        VStack(spacing: 16) {
                            Text("\(count)").font(.system(size: 72, weight: .medium, design: .rounded))
                                .monospacedDigit()
                            Button("取消倒计时", action: controls.cancelCapture).padding(12).background(
                                .black.opacity(0.6), in: Capsule())
                        }
                    }
                    if camera.isBusy || camera.recording.phase == .starting || camera.recording.phase == .finishing {
                        ProgressView().tint(.white)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .overlay(alignment: .top) {
                        if let message = camera.controlMessage ?? camera.photoRendererFailure ?? camera.message
                            ?? camera.photoMessage
                        {
                            Text(message).font(.caption).multilineTextAlignment(.center).padding(8).background(
                                .black.opacity(0.6))
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if camera.recording.phase == .recording, let started = camera.recording.startedAt {
                            HStack(spacing: 8) {
                                Circle().fill(.red).frame(width: 8, height: 8)
                                Text(started, style: .timer).monospacedDigit()
                                Text("聆听已暂停").font(.caption)
                            }.padding(8).background(.black.opacity(0.65), in: Capsule()).padding(8)
                        } else if let id = camera.recording.id,
                            camera.recording.phase == .ready || camera.recording.phase == .failed
                        {
                            HStack(spacing: 20) {
                                Button("保存视频") { controls.saveVideo(id) }
                                Button("忽略") { controls.ignoreVideo(id) }
                            }.padding(12).background(.black.opacity(0.75), in: Capsule())
                                .disabled(camera.controlBusy).padding(8)
                        }
                    }
                VStack(spacing: 8) {
                    HStack(spacing: 16) {
                        ForEach(["photo", "video"], id: \.self) { mode in
                            Button(mode == "photo" ? "照片" : "视频") {
                                updateSettings {
                                    $0.mode = mode
                                    $0.flash = "off"
                                }
                            }
                            .foregroundStyle(camera.settings.mode == mode ? .yellow : .white)
                            .frame(minWidth: 52, minHeight: 44)
                            .disabled(settingsLocked || camera.capturedPhoto != nil)
                        }
                        settingsMenu
                    }.font(.subheadline)
                    HStack(spacing: 24) {
                        Button(action: controls.switchCamera) {
                            Image(systemName: "arrow.triangle.2.circlepath.camera").frame(width: 48, height: 48)
                        }.accessibilityLabel("切换镜头").disabled(!camera.canSwitchCamera)
                        shutter
                        Menu {
                            ForEach([1.0, 2.0, 3.0, 6.0].filter { $0 <= camera.settings.maximumZoom }, id: \.self) {
                                zoom in
                                Button(String(format: "%.0f×", zoom)) { updateSettings { $0.zoom = zoom } }
                            }
                        } label: {
                            Text(String(format: "%.1f×", camera.settings.zoom)).monospacedDigit().frame(
                                width: 48, height: 48)
                        }.accessibilityLabel("变焦").disabled(settingsLocked)
                    }
                }.buttonStyle(.plain).frame(height: 140)
            }.foregroundStyle(.white).background(.black)
        }
        private var settingsLocked: Bool {
            !camera.isVisible || !camera.isEnabled || camera.controlBusy || camera.photoBusy || camera.isBusy
                || camera.recording.active || camera.recordedVideo != nil
                || (camera.recording.phase == .failed && camera.recording.id != nil)
        }
        private func updateSettings(_ change: (inout CameraSettings) -> Void) {
            var settings = camera.settings
            change(&settings)
            controls.configure(settings)
        }
        private var settingsMenu: some View {
            Menu {
                if camera.settings.mode == "photo" {
                    Menu("倒计时：\(camera.settings.delaySeconds) 秒") {
                        ForEach([0, 3, 5, 10], id: \.self) { delay in
                            Button(delay == 0 ? "立即拍摄" : "\(delay) 秒") { updateSettings { $0.delaySeconds = delay } }
                        }
                    }
                    Menu("闪光灯") {
                        ForEach(camera.settings.supportedFlash, id: \.self) { flash in
                            Button(flash == "off" ? "关闭" : flash == "on" ? "开启" : "自动") {
                                updateSettings { $0.flash = flash }
                            }
                        }
                    }
                } else {
                    Menu("最长录制：\(camera.settings.durationSeconds) 秒") {
                        ForEach([10, 30, 60, 300, 600], id: \.self) { duration in
                            Button("\(duration) 秒") { updateSettings { $0.durationSeconds = duration } }
                        }
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
            }.accessibilityLabel("拍摄设置").disabled(settingsLocked)
        }
        @ViewBuilder private var shutter: some View {
            if camera.recording.phase == .recording {
                Button(action: controls.stopRecording) {
                    RoundedRectangle(cornerRadius: 5).fill(.red).frame(width: 28, height: 28)
                        .frame(width: 64, height: 64).overlay(Circle().stroke(.white, lineWidth: 2))
                }.accessibilityLabel("停止录像").accessibilityIdentifier("camera.record.stop")
                    .disabled(camera.controlBusy)
            } else if camera.countdown != nil {
                Button("取消", action: controls.cancelCapture).frame(width: 64, height: 64)
            } else if camera.isEnabled && camera.isVisible {
                Button {
                    if camera.settings.mode == "video" { controls.startRecording() } else { controls.takePhoto() }
                } label: {
                    Circle().fill(camera.settings.mode == "video" ? .red : .white).frame(width: 54, height: 54).padding(
                        5
                    )
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                }.accessibilityLabel(camera.settings.mode == "video" ? "开始录像" : "拍照")
                    .accessibilityIdentifier("camera.capture").disabled(settingsLocked)
            } else if camera.needsSettings {
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.frame(minHeight: 44)
            } else {
                Button("开启相机", action: controls.open).frame(minHeight: 44).disabled(camera.controlBusy || camera.isBusy)
            }
        }
    }
#endif
