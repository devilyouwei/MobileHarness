import CoreVideo
import Foundation

/// UI-owned immutable display value; retains pixels without exposing device or model ownership.
public struct CameraVideoFrame: @unchecked Sendable {
    let pixels: CVPixelBuffer
    public let width: Int
    public let height: Int
    public let rotation: Int
    public let portraitRotation: Int?
    public let sequence: UInt64
    public let capturedAt: ContinuousClock.Instant
    public init(
        pixels: CVPixelBuffer, width: Int, height: Int, rotation: Int, sequence: UInt64,
        capturedAt: ContinuousClock.Instant, portraitRotation: Int? = nil
    ) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.rotation = rotation
        self.portraitRotation = portraitRotation
        self.sequence = sequence
        self.capturedAt = capturedAt
    }
}

/// Interface coordinates, not physical-device gravity. Values are clockwise turns from portrait.
enum CameraInterfaceOrientation: Int, CaseIterable, Sendable {
    case portrait = 0
    case landscapeLeft = 1
    case portraitUpsideDown = 2
    case landscapeRight = 3
}

struct CameraPreviewBasis: Equatable, Sendable {
    let rotation: Int
    let portraitRotation: Int?
    func displayRotation(_ orientation: CameraInterfaceOrientation) -> Int {
        portraitRotation.map { ($0 + orientation.rawValue) % 4 } ?? rotation
    }
    func turns(_ orientation: CameraInterfaceOrientation) -> Int {
        (displayRotation(orientation) - rotation + 4) % 4
    }
    func point(_ point: CGPoint, orientation: CameraInterfaceOrientation, mirrored: Bool) -> CGPoint {
        let rotated: CGPoint
        switch turns(orientation) {
        case 1: rotated = CGPoint(x: 1 - point.y, y: point.x)
        case 2: rotated = CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 3: rotated = CGPoint(x: point.y, y: 1 - point.x)
        default: rotated = point
        }
        return CGPoint(x: mirrored ? 1 - rotated.x : rotated.x, y: rotated.y)
    }
    /// Face attention arrives mirrored in capture coordinates; mirror once in the display axes.
    func gaze(_ gaze: CGSize, orientation: CameraInterfaceOrientation, mirrored: Bool) -> CGSize {
        let x = mirrored ? -gaze.width : gaze.width
        let y = gaze.height
        let rotated: CGSize
        switch turns(orientation) {
        case 1: rotated = CGSize(width: -y, height: x)
        case 2: rotated = CGSize(width: -x, height: -y)
        case 3: rotated = CGSize(width: y, height: -x)
        default: rotated = CGSize(width: x, height: y)
        }
        return CGSize(width: mirrored ? -rotated.width : rotated.width, height: rotated.height)
    }
}

/// Shared aspect-fill geometry for raw texture sampling and upright model joints.
struct CameraPreviewGeometry {
    let basis: CameraPreviewBasis
    let orientation: CameraInterfaceOrientation
    let imageSize: CGSize
    let size: CGSize
    let scale: CGFloat
    init(frame: CameraVideoFrame, size: CGSize, orientation: CameraInterfaceOrientation) {
        basis = CameraPreviewBasis(rotation: frame.rotation, portraitRotation: frame.portraitRotation)
        self.orientation = orientation
        self.size = size
        let swapped = basis.turns(orientation) % 2 != 0
        imageSize = CGSize(width: swapped ? frame.height : frame.width, height: swapped ? frame.width : frame.height)
        scale = max(size.width / imageSize.width, size.height / imageSize.height)
    }
    var displayRotation: Int { basis.displayRotation(orientation) }
    var crop: CGSize {
        CGSize(width: size.width / (imageSize.width * scale), height: size.height / (imageSize.height * scale))
    }
    func project(_ point: CGPoint, mirrored: Bool) -> CGPoint {
        let point = basis.point(point, orientation: orientation, mirrored: mirrored)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGPoint(x: (size.width - width) / 2 + point.x * width, y: (size.height - height) / 2 + point.y * height)
    }
}

/// Immutable submission; device capture and UI state ownership stay outside the renderer.
struct CameraRenderSnapshot: Sendable {
    var frame: CameraVideoFrame?
    var pose: PoseOverlay?
    var mirrored: Bool
    var size: CGSize
    var pixelSize: CGSize
    var orientation: CameraInterfaceOrientation = .portrait

    func matches(_ other: Self) -> Bool {
        frame?.sequence == other.frame?.sequence && frame?.capturedAt == other.frame?.capturedAt
            && frame?.width == other.frame?.width && frame?.height == other.frame?.height
            && frame?.rotation == other.frame?.rotation && frame?.portraitRotation == other.frame?.portraitRotation
            && orientation == other.orientation && pose == other.pose
            && mirrored == other.mirrored && size == other.size && pixelSize == other.pixelSize
    }
}

/// One latest value, no history. The owner serializes access with a mutex.
struct CameraRenderMailbox: Sendable {
    private(set) var stopped = false
    private var latest: CameraRenderSnapshot?
    private(set) var pending = false
    mutating func submit(_ value: CameraRenderSnapshot) -> Bool {
        guard !stopped, latest.map({ !value.matches($0) }) ?? true else { return false }
        latest = value
        pending = true
        return true
    }
    mutating func take() -> CameraRenderSnapshot? {
        guard !stopped, pending else { return nil }
        pending = false
        return latest
    }
    @discardableResult mutating func stop() -> Bool {
        guard !stopped else { return false }
        stopped = true
        latest = nil
        pending = false
        return true
    }
}

/// Cached CPU mesh; camera frame identity alone never invalidates the skeleton geometry.
struct CameraSkeletonMesh {
    static let maximumVertices = 6 * (16 * 6 + 17 * 24)
    private(set) var revision: UInt64 = 0
    private(set) var vertices: [SIMD2<Float>] = []
    private var pose: PoseOverlay?
    private var size: CGSize = .zero
    private var imageSize: CGSize = .zero
    private var mirrored = false
    private var rotation = -1
    private var portraitRotation: Int?
    private var orientation = CameraInterfaceOrientation.portrait

    mutating func update(_ value: CameraRenderSnapshot) {
        let imageSize = CGSize(width: value.frame?.width ?? 0, height: value.frame?.height ?? 0)
        let rotation = value.frame?.rotation ?? -1
        guard
            pose != value.pose || size != value.size || self.imageSize != imageSize
                || mirrored != value.mirrored || self.rotation != rotation
                || portraitRotation != value.frame?.portraitRotation || orientation != value.orientation
        else { return }
        pose = value.pose
        size = value.size
        self.imageSize = imageSize
        mirrored = value.mirrored
        self.rotation = rotation
        portraitRotation = value.frame?.portraitRotation
        orientation = value.orientation
        revision &+= 1
        vertices = Self.makeVertices(value)
    }
    private static func makeVertices(_ value: CameraRenderSnapshot) -> [SIMD2<Float>] {
        guard let frame = value.frame, let pose = value.pose, frame.rotation == pose.rotation,
            frame.width > 0, frame.height > 0, value.size.width > 0, value.size.height > 0,
            pose.people.count <= 6, pose.people.allSatisfy({ $0.count == 17 })
        else { return [] }
        let size = value.size
        let geometry = CameraPreviewGeometry(frame: frame, size: size, orientation: value.orientation)
        var vertices: [SIMD2<Float>] = []
        vertices.reserveCapacity(maximumVertices)
        func vertex(_ point: CGPoint) -> SIMD2<Float> {
            SIMD2(Float(point.x / size.width * 2 - 1), Float(1 - point.y / size.height * 2))
        }
        func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) {
            vertices.append(contentsOf: [vertex(a), vertex(b), vertex(c)])
        }
        let edges = [
            (0, 1), (0, 2), (1, 3), (2, 4), (5, 6), (5, 7), (7, 9), (6, 8), (8, 10), (5, 11), (6, 12), (11, 12),
            (11, 13), (13, 15), (12, 14), (14, 16),
        ]
        for person in pose.people where person.count == 17 {
            let points = person.map { point in
                let x = CGFloat(point.x) / 10000
                let y = CGFloat(point.y) / 10000
                return geometry.project(CGPoint(x: x, y: y), mirrored: value.mirrored)
            }
            for (a, b) in edges where person[a].confidence >= 300 && person[b].confidence >= 300 {
                let first = points[a]
                let second = points[b]
                let length = hypot(second.x - first.x, second.y - first.y)
                guard length > 0 else { continue }
                let dx = -(second.y - first.y) / length * 1.25
                let dy = (second.x - first.x) / length * 1.25
                let p = CGPoint(x: first.x + dx, y: first.y + dy)
                let q = CGPoint(x: first.x - dx, y: first.y - dy)
                let r = CGPoint(x: second.x + dx, y: second.y + dy)
                let t = CGPoint(x: second.x - dx, y: second.y - dy)
                triangle(p, q, r)
                triangle(r, q, t)
            }
            for (index, point) in person.enumerated() where point.confidence >= 300 {
                let center = points[index]
                for segment in 0..<8 {
                    let a = CGFloat(segment) * .pi / 4
                    let b = CGFloat(segment + 1) * .pi / 4
                    triangle(
                        center, CGPoint(x: center.x + cos(a) * 3, y: center.y + sin(a) * 3),
                        CGPoint(x: center.x + cos(b) * 3, y: center.y + sin(b) * 3))
                }
            }
        }
        return vertices
    }
}
