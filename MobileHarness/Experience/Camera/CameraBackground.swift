import AVFoundation
import AgentCore
import PlatformKit
import SwiftUI
import UIKit

/// Camera is always behind content; preview and dimming layer never intercept touches.
@MainActor
struct CameraConversationSurface<Content: View>: View {
    @Bindable var camera: CameraCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(source: camera.preview, facing: camera.facing, skeleton: camera.skeleton)
                .ignoresSafeArea()
                .opacity(camera.isVisible ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            content()
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 12) {
                HStack(spacing: 12) {
                    Button(action: camera.toggle) {
                        Image(systemName: camera.isEnabled ? "video.fill" : "video.slash.fill")
                            .frame(width: 48, height: 48)
                    }
                    .accessibilityLabel(camera.isEnabled ? "关闭摄像头" : "开启摄像头")
                    .accessibilityValue(camera.isVisible ? "已开启" : (camera.isEnabled ? "等待相机" : "已关闭"))
                    .accessibilityIdentifier("camera.toggle")
                    Button(action: camera.switchCamera) {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .frame(width: 48, height: 48)
                    }
                    .disabled(!camera.isEnabled || camera.isBusy)
                    .accessibilityLabel(camera.facing == .front ? "切换到后置摄像头" : "切换到前置摄像头")
                    .accessibilityIdentifier("camera.switch")
                    Menu {
                        Picker(
                            "灰度变化阈值",
                            selection: Binding(get: { camera.changeThreshold }, set: camera.setChangeThreshold)
                        ) {
                            Text("1%").tag(0.01)
                            Text("3%（默认）").tag(0.03)
                            Text("5%").tag(0.05)
                            Text("10%").tag(0.10)
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3").frame(width: 44, height: 48)
                    }
                    .accessibilityLabel("识别抽帧阈值")
                    .accessibilityValue("\(Int(camera.changeThreshold * 100))%")
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
                            Button("重试", action: camera.retry).disabled(camera.isBusy)
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
            .padding(.top, 12)
        }
        .preferredColorScheme(.dark)
        .task {
            camera.setForeground(scenePhase == .active)
            await camera.observe()
        }
        .onChange(of: scenePhase) { _, phase in camera.setForeground(phase == .active) }
        .onDisappear { camera.setForeground(false) }
    }
}

@MainActor
private struct CameraPreview: UIViewRepresentable {
    let source: CameraPreviewSource
    let facing: CameraFacing
    let skeleton: PoseOverlay?
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        source.connect(view.previewLayer)
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {
        view.update(source: source, facing: facing, skeleton: skeleton)
    }
    static func dismantleUIView(_ view: PreviewView, coordinator: Void) { view.disconnect() }
}

@MainActor
private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?
    private var facing: CameraFacing?
    private var source: CameraPreviewSource?
    private var skeleton: PoseOverlay?
    private let bones = CAShapeLayer()
    private let joints = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        bones.strokeColor = UIColor.systemGreen.cgColor
        bones.fillColor = UIColor.clear.cgColor
        bones.lineWidth = 2.5
        bones.lineCap = .round
        joints.fillColor = UIColor.systemGreen.cgColor
        layer.addSublayer(bones)
        layer.addSublayer(joints)
    }
    required init?(coder: NSCoder) { nil }

    func update(source: CameraPreviewSource, facing: CameraFacing, skeleton: PoseOverlay?) {
        self.source = source
        self.skeleton = skeleton
        if self.facing != facing || rotation == nil {
            self.facing = facing
            observation = nil
            rotation = source.rotationCoordinator(facing: facing, layer: previewLayer)
            observation = rotation?.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) {
                [weak self] _, _ in
                // AVFoundation documents rotation KVO delivery on the main queue.
                MainActor.assumeIsolated { self?.applyOrientation() }
            }
        }
        applyOrientation()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        applyOrientation()
    }
    private func applyOrientation() {
        if let rotation { source?.setCaptureRotation(rotation.videoRotationAngleForHorizonLevelCapture) }
        guard let connection = previewLayer.connection else { return }
        if let angle = rotation?.videoRotationAngleForHorizonLevelPreview,
            connection.isVideoRotationAngleSupported(angle)
        {
            connection.videoRotationAngle = angle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = facing == .front
        }
        drawSkeleton()
    }
    private func drawSkeleton() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        bones.frame = bounds
        joints.frame = bounds
        bones.path = nil
        joints.path = nil
        guard let skeleton, let rotation,
            skeleton.rotation == CameraPreviewSource.quarterTurns(rotation.videoRotationAngleForHorizonLevelCapture)
        else { return }
        let lines = UIBezierPath()
        let dots = UIBezierPath()
        let edges = [
            (0, 1), (0, 2), (1, 3), (2, 4), (5, 6), (5, 7), (7, 9), (6, 8), (8, 10),
            (5, 11), (6, 12), (11, 12), (11, 13), (13, 15), (12, 14), (14, 16),
        ]
        for person in skeleton.people where person.count == 17 {
            let points = person.map { joint -> CGPoint in
                let point = joint.sensorPoint(rotation: skeleton.rotation)
                return previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: point.x, y: point.y))
            }
            for (a, b) in edges where person[a].confidence >= 300 && person[b].confidence >= 300 {
                lines.move(to: points[a])
                lines.addLine(to: points[b])
            }
            for (index, joint) in person.enumerated() where joint.confidence >= 300 {
                let point = points[index]
                dots.append(UIBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)))
            }
        }
        bones.path = lines.cgPath
        joints.path = dots.cgPath
    }

    func disconnect() {
        observation = nil
        rotation = nil
        previewLayer.session = nil
    }
}
