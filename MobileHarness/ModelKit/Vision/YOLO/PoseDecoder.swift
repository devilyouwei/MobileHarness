import Foundation
import ModelKit
import ModelKitCoreML

struct PoseLetterbox: Sendable {
    let width: Int
    let height: Int
    let left: Int
    let top: Int
    let scaleX: Float
    let scaleY: Float
    init(image: ImageFrame) {
        let scale = min(640.0 / Double(image.width), 640.0 / Double(image.height))
        width = max(1, Int((Double(image.width) * scale).rounded()))
        height = max(1, Int((Double(image.height) * scale).rounded()))
        left = (640 - width) / 2
        top = (640 - height) / 2
        scaleX = Float(width) / Float(image.width)
        scaleY = Float(height) / Float(image.height)
    }
    func render(_ image: ImageFrame) throws -> Data {
        var output = [UInt8](repeating: 114, count: 640 * 640 * 3)
        let source = [UInt8](image.rgb)
        for y in 0..<height {
            try Task.checkCancellation()
            let sy = max(0, min(Float(image.height - 1), (Float(y) + 0.5) / scaleY - 0.5))
            let y0 = Int(sy)
            let y1 = min(y0 + 1, image.height - 1)
            let fy = sy - Float(y0)
            for x in 0..<width {
                let sx = max(0, min(Float(image.width - 1), (Float(x) + 0.5) / scaleX - 0.5))
                let x0 = Int(sx)
                let x1 = min(x0 + 1, image.width - 1)
                let fx = sx - Float(x0)
                for c in 0..<3 {
                    let a = Float(source[(y0 * image.width + x0) * 3 + c])
                    let b = Float(source[(y0 * image.width + x1) * 3 + c])
                    let d = Float(source[(y1 * image.width + x0) * 3 + c])
                    let e = Float(source[(y1 * image.width + x1) * 3 + c])
                    output[((y + top) * 640 + x + left) * 3 + c] = UInt8(
                        max(0, min(255, ((a * (1 - fx) + b * fx) * (1 - fy) + (d * (1 - fx) + e * fx) * fy).rounded())))
                }
            }
        }
        return Data(output)
    }
}

enum PoseDecoder {
    static func decode(_ tensor: CoreMLTensor, letterbox: PoseLetterbox) throws -> [PersonPose] {
        guard tensor.shape == [1, 56, 8400], tensor.values.count == 56 * 8400,
            tensor.values.allSatisfy(\.isFinite)
        else { throw CapabilityError.invalidRequest("Invalid YOLO pose tensor") }
        let v = tensor.values
        func value(_ channel: Int, _ index: Int) -> Float { v[channel * 8400 + index] }
        var candidates: [Int] = []
        for i in 0..<8400 {
            let score = value(4, i)
            guard (0...1).contains(score) else { throw CapabilityError.invalidRequest("Invalid person score") }
            if score >= 0.25 && value(2, i) > 0 && value(3, i) > 0 { candidates.append(i) }
        }
        candidates.sort { value(4, $0) == value(4, $1) ? $0 < $1 : value(4, $0) > value(4, $1) }
        func box(_ i: Int) -> PoseBox {
            PoseBox(
                x: value(0, i) - value(2, i) / 2, y: value(1, i) - value(3, i) / 2,
                width: value(2, i), height: value(3, i))
        }
        func iou(_ a: PoseBox, _ b: PoseBox) -> Double {
            let w = max(
                0, min(Double(a.x) + Double(a.width), Double(b.x) + Double(b.width)) - max(Double(a.x), Double(b.x)))
            let h = max(
                0, min(Double(a.y) + Double(a.height), Double(b.y) + Double(b.height)) - max(Double(a.y), Double(b.y)))
            let intersection = w * h
            return intersection
                / (Double(a.width) * Double(a.height) + Double(b.width) * Double(b.height) - intersection)
        }
        var selected: [Int] = []
        // Bound quadratic NMS work; higher scoring candidates take precedence.
        for i in candidates.prefix(300) {
            try Task.checkCancellation()
            if selected.allSatisfy({ iou(box(i), box($0)) <= 0.45 }) { selected.append(i) }
            if selected.count == 100 { break }
        }
        return try selected.map { i in
            let b = box(i)
            let points = try BodyJoint.allCases.map { joint in
                let c = 5 + joint.rawValue * 3
                let score = value(c + 2, i)
                guard (0...1).contains(score) else { throw CapabilityError.invalidRequest("Invalid joint score") }
                return PoseKeypoint(
                    joint: joint,
                    x: (value(c, i) - Float(letterbox.left)) / letterbox.scaleX,
                    y: (value(c + 1, i) - Float(letterbox.top)) / letterbox.scaleY, confidence: score)
            }
            return PersonPose(
                box: PoseBox(
                    x: (b.x - Float(letterbox.left)) / letterbox.scaleX,
                    y: (b.y - Float(letterbox.top)) / letterbox.scaleY,
                    width: b.width / letterbox.scaleX, height: b.height / letterbox.scaleY),
                confidence: value(4, i), keypoints: points)
        }
    }
}
