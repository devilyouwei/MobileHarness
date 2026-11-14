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
                if camera.perceptionEnabled && camera.isVisible && camera.faceVisible
                    && (camera.windows?.hasVisibleBackground() ?? true)
                {
                    CameraFrameView(state: camera)
                        .overlay {
                            LinearGradient(
                                colors: [
                                    Color(red: 0.015, green: 0.035, blue: 0.075).opacity(0.82),
                                    .black.opacity(0.45), Color(red: 0.01, green: 0.025, blue: 0.055).opacity(0.9),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        }
                        .ignoresSafeArea().opacity(0.30)
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
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
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
                    .accessibilityLabel(
                        camera.perceptionEnabled ? appCopy.text("Turn off vision") : appCopy.text("Turn on vision")
                    )
                    .accessibilityValue(
                        camera.perceptionEnabled
                            ? (camera.isVisible ? appCopy.text("On") : appCopy.text("Waiting for camera"))
                            : appCopy.text("Off")
                    )
                    .accessibilityIdentifier("camera.toggle")
                    .disabled(camera.isBusy || camera.controlBusy || (blocksNewActions && !camera.perceptionEnabled))
                    if camera.perceptionEnabled {
                        HStack(spacing: 12) {
                            Button(action: controls.switchPerceptionCamera) {
                                Image(systemName: "arrow.triangle.2.circlepath.camera")
                                    .frame(width: 48, height: 48)
                            }
                            .disabled(!camera.canSwitch(.perception))
                            .accessibilityLabel(
                                camera.facing == .front
                                    ? appCopy.text("Switch to the rear camera")
                                    : appCopy.text("Switch to the front camera")
                            )
                            .accessibilityIdentifier("camera.switch")
                        }
                        .font(.system(size: 18, weight: .medium))
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                    }
                    Button(action: openSettings) {
                        Image(systemName: "gearshape").frame(width: 48, height: 48)
                    }
                    .accessibilityLabel(appCopy.text("Settings"))
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
                        Text(appCopy.text(message)).font(.footnote)
                            .multilineTextAlignment(.trailing)
                        if camera.needsSettings {
                            Button(appCopy.text("Open settings")) {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        } else {
                            Button(appCopy.text("Retry"), action: controls.retryPerception).disabled(
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
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
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
                    .accessibilityLabel(
                        statisticsExpanded
                            ? appCopy.text("Hide performance metrics") : appCopy.text("Show performance metrics")
                    )
                    .accessibilityValue(statisticsExpanded ? appCopy.text("Expanded") : appCopy.text("Collapsed"))
                    .accessibilityIdentifier("camera.poseStatistics.toggle")
                    if statisticsExpanded {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(
                                appCopy.format(
                                    "Interval %@",
                                    String(describing: metric(statistics.detectionIntervalMilliseconds, suffix: "ms"))))
                            Text(
                                appCopy.format(
                                    "Image motion %@",
                                    String(describing: statistics.imageMotion.map { String(format: "%.2f", $0) } ?? "—")
                                ))
                            Text(
                                appCopy.format(
                                    "Wait %@", String(describing: metric(statistics.queueMilliseconds, suffix: "ms"))))
                            Text(
                                appCopy.format(
                                    "Inference %@",
                                    String(describing: metric(statistics.inferenceMilliseconds, suffix: "ms"))))
                            Text(
                                appCopy.format(
                                    "Total latency %@",
                                    String(describing: metric(statistics.totalMilliseconds, suffix: "ms"))))
                            Text(appCopy.format("Skipped %@ frames", String(describing: statistics.replacements)))
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
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
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
            ZStack(alignment: .bottom) {
                ZStack {
                    Color.black
                    if rendersPreview && camera.isEnabled && camera.isVisible && camera.recordedVideo == nil {
                        preview().frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                    }
                    if let video = camera.recordedVideo, rendersPreview {
                        LocalVideoPlayer(file: video.file)
                    }
                    if let count = camera.countdown {
                        VStack(spacing: 16) {
                            Text("\(count)").font(.system(size: 72, weight: .medium, design: .rounded))
                                .monospacedDigit()
                            Button(appCopy.text("Cancel countdown"), action: controls.cancelCapture).padding(12)
                                .background(
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
                            Text(appCopy.text(message)).font(.caption).multilineTextAlignment(.center).padding(8)
                                .background(
                                    .black.opacity(0.6))
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if camera.recording.phase == .recording, let started = camera.recording.startedAt {
                            HStack(spacing: 8) {
                                Circle().fill(.red).frame(width: 8, height: 8)
                                Text(started, style: .timer).monospacedDigit()
                                Text(appCopy.text("Listening paused")).font(.caption)
                            }.padding(8).background(.black.opacity(0.65), in: Capsule()).padding(8).padding(
                                .bottom, 140)
                        } else if let id = camera.recording.id,
                            camera.recording.phase == .ready || camera.recording.phase == .failed
                        {
                            HStack(spacing: 20) {
                                Button(appCopy.text("Save video")) { controls.saveVideo(id) }
                                Button(appCopy.text("Discard")) { controls.ignoreVideo(id) }
                            }.padding(12).background(.black.opacity(0.75), in: Capsule())
                                .disabled(camera.controlBusy).padding(8).padding(.bottom, 140)
                        }
                    }
                VStack(spacing: 8) {
                    HStack(spacing: 16) {
                        ForEach(["photo", "video"], id: \.self) { mode in
                            Button(mode == "photo" ? appCopy.text("Photo") : appCopy.text("Video")) {
                                updateSettings {
                                    $0.mode = mode
                                    $0.flash = "off"
                                }
                            }
                            .foregroundStyle(camera.settings.mode == mode ? .yellow : .white)
                            .frame(minWidth: 52, minHeight: 44)
                            .disabled(settingsLocked)
                        }
                        settingsMenu
                    }.font(.subheadline)
                    HStack(spacing: 24) {
                        Button(action: controls.switchCamera) {
                            Image(systemName: "arrow.triangle.2.circlepath.camera").frame(width: 48, height: 48)
                        }.accessibilityLabel(appCopy.text("Switch camera")).disabled(!camera.canSwitchCamera)
                        shutter
                        Menu {
                            ForEach([1.0, 2.0, 3.0, 6.0].filter { $0 <= camera.settings.maximumZoom }, id: \.self) {
                                zoom in
                                Button(String(format: "%.0f×", zoom)) { updateSettings { $0.zoom = zoom } }
                            }
                        } label: {
                            Text(String(format: "%.1f×", camera.settings.zoom)).monospacedDigit().frame(
                                width: 48, height: 48)
                        }.accessibilityLabel(appCopy.text("Zoom")).disabled(settingsLocked)
                    }
                }.buttonStyle(.plain).frame(height: 140).frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            colors: [.black.opacity(0.15), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                if rendersPreview {
                    CameraGalleryView(camera: camera, controls: controls)
                    if let photo = camera.capturedPhoto {
                        CapturedPhotoView(photo: photo).id(photo.id)
                    }
                }
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
                    Menu(appCopy.format("Countdown: %@ sec", String(camera.settings.delaySeconds))) {
                        ForEach([0, 3, 5, 10], id: \.self) { delay in
                            Button(delay == 0 ? appCopy.text("Shoot now") : appCopy.format("%@ sec", String(delay))) {
                                updateSettings { $0.delaySeconds = delay }
                            }
                        }
                    }
                    Menu(appCopy.text("Flash")) {
                        ForEach(camera.settings.supportedFlash, id: \.self) { flash in
                            Button(
                                flash == "off"
                                    ? appCopy.text("Off") : flash == "on" ? appCopy.text("On") : appCopy.text("Auto")
                            ) {
                                updateSettings { $0.flash = flash }
                            }
                        }
                    }
                } else {
                    Menu(appCopy.format("Maximum recording: %@ sec", String(camera.settings.durationSeconds))) {
                        ForEach([10, 30, 60, 300, 600], id: \.self) { duration in
                            Button(appCopy.format("%@ sec", String(duration))) {
                                updateSettings { $0.durationSeconds = duration }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
            }.accessibilityLabel(appCopy.text("Capture settings")).disabled(settingsLocked)
        }
        @ViewBuilder private var shutter: some View {
            if camera.recording.phase == .recording {
                Button(action: controls.stopRecording) {
                    RoundedRectangle(cornerRadius: 5).fill(.red).frame(width: 28, height: 28)
                        .frame(width: 64, height: 64).overlay(Circle().stroke(.white, lineWidth: 2))
                }.accessibilityLabel(appCopy.text("Stop recording")).accessibilityIdentifier("camera.record.stop")
                    .disabled(camera.controlBusy)
            } else if camera.countdown != nil {
                Button(appCopy.text("Cancel"), action: controls.cancelCapture).frame(width: 64, height: 64)
            } else if camera.isEnabled && camera.isVisible {
                Button {
                    if camera.settings.mode == "video" { controls.startRecording() } else { controls.takePhoto() }
                } label: {
                    Circle().fill(camera.settings.mode == "video" ? .red : .white).frame(width: 54, height: 54).padding(
                        5
                    )
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                }.accessibilityLabel(
                    camera.settings.mode == "video" ? appCopy.text("Start recording") : appCopy.text("Take photo")
                )
                .accessibilityIdentifier("camera.capture").disabled(settingsLocked)
            } else if camera.needsSettings {
                Button(appCopy.text("Open System Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.frame(minHeight: 44)
            } else {
                Button(appCopy.text("Start camera"), action: controls.open).frame(minHeight: 44).disabled(
                    camera.controlBusy || camera.isBusy)
            }
        }
    }
#endif
