import AVFoundation
import AgentCore
import PlatformKit
import SwiftUI
import UIKit

@MainActor
struct CameraPreviewAdapter: UIViewRepresentable {
    let source: CameraPreviewSource
    let facing: CameraFacing
    let skeleton: PoseOverlay?
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        source.connect(view.previewLayer)
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {
        view.update(source: source, facing: facing, skeleton: skeleton)
    }
    static func dismantleUIView(_ view: PreviewView, coordinator: Void) { view.disconnect() }
}

@MainActor
final class PreviewView: UIView {
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
