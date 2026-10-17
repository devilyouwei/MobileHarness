import CoreVideo
import Foundation

/// UI-owned immutable display value; retains pixels without exposing device or model ownership.
public struct CameraVideoFrame: @unchecked Sendable {
    let pixels: CVPixelBuffer
    public let width: Int
    public let height: Int
    public let rotation: Int
    public let sequence: UInt64
    public let capturedAt: ContinuousClock.Instant
    public init(
        pixels: CVPixelBuffer, width: Int, height: Int, rotation: Int, sequence: UInt64,
        capturedAt: ContinuousClock.Instant
    ) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.rotation = rotation
        self.sequence = sequence
        self.capturedAt = capturedAt
    }
}

/// Immutable submission; device capture and UI state ownership stay outside the renderer.
struct CameraRenderSnapshot: Sendable {
    var frame: CameraVideoFrame?
    var pose: PoseOverlay?
    var mirrored: Bool
    var size: CGSize
    var pixelSize: CGSize

    func matches(_ other: Self) -> Bool {
        frame?.sequence == other.frame?.sequence && frame?.capturedAt == other.frame?.capturedAt
            && frame?.width == other.frame?.width && frame?.height == other.frame?.height
            && frame?.rotation == other.frame?.rotation && pose == other.pose
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

    mutating func update(_ value: CameraRenderSnapshot) {
        let imageSize = CGSize(width: value.frame?.width ?? 0, height: value.frame?.height ?? 0)
        let rotation = value.frame?.rotation ?? -1
        guard
            pose != value.pose || size != value.size || self.imageSize != imageSize
                || mirrored != value.mirrored || self.rotation != rotation
        else { return }
        pose = value.pose
        size = value.size
        self.imageSize = imageSize
        mirrored = value.mirrored
        self.rotation = rotation
        revision &+= 1
        vertices = Self.makeVertices(value)
    }
    private static func makeVertices(_ value: CameraRenderSnapshot) -> [SIMD2<Float>] {
        guard let frame = value.frame, let pose = value.pose, frame.rotation == pose.rotation,
            frame.width > 0, frame.height > 0, value.size.width > 0, value.size.height > 0,
            pose.people.count <= 6, pose.people.allSatisfy({ $0.count == 17 })
        else { return [] }
        let size = value.size
        let mirrored = value.mirrored
        let scale = max(size.width / CGFloat(frame.width), size.height / CGFloat(frame.height))
        let width = CGFloat(frame.width) * scale
        let height = CGFloat(frame.height) * scale
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
                return CGPoint(
                    x: (size.width - width) / 2 + (mirrored ? 1 - x : x) * width,
                    y: (size.height - height) / 2 + y * height)
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
