import Foundation
import ModelKit
import ModelKitCoreML

/// Pinned YOLO26 end-to-end output: [x1, y1, x2, y2, confidence, class, 17×(x,y,confidence)].
/// The one-to-one head performs selection in the graph; do not apply legacy NMS again.
enum PoseDecoder {
    static func decode(_ tensor: CoreMLTensor, letterbox: CoreMLImageLayout) throws -> [PersonPose] {
        guard tensor.shape == [1, 300, 57], tensor.values.count == 300 * 57,
            tensor.values.allSatisfy(\.isFinite)
        else { throw CapabilityError.invalidRequest("Invalid YOLO26 end-to-end pose tensor") }
        let values = tensor.values
        var accepted: [Int] = []
        for row in 0..<300 {
            let base = row * 57
            let score = values[base + 4]
            guard (0...1).contains(score) else { throw CapabilityError.invalidRequest("Invalid person score") }
            if score >= 0.25 {
                guard values[base + 5] == 0 else { throw CapabilityError.invalidRequest("Expected person class") }
                if values[base + 2] > values[base], values[base + 3] > values[base + 1] { accepted.append(row) }
            }
        }
        // Stable score order for the UI's six-person budget, without suppressing overlapping people.
        accepted.sort {
            let a = values[$0 * 57 + 4]
            let b = values[$1 * 57 + 4]
            return a == b ? $0 < $1 : a > b
        }
        return try accepted.map { row in
            let base = row * 57
            let points = try BodyJoint.allCases.map { joint in
                let i = base + 6 + joint.rawValue * 3
                let score = values[i + 2]
                guard (0...1).contains(score) else { throw CapabilityError.invalidRequest("Invalid joint score") }
                return PoseKeypoint(
                    joint: joint,
                    x: (values[i] - letterbox.offsetX) / letterbox.scaleX,
                    y: (values[i + 1] - letterbox.offsetY) / letterbox.scaleY, confidence: score)
            }
            return PersonPose(
                box: PoseBox(
                    x: (values[base] - letterbox.offsetX) / letterbox.scaleX,
                    y: (values[base + 1] - letterbox.offsetY) / letterbox.scaleY,
                    width: (values[base + 2] - values[base]) / letterbox.scaleX,
                    height: (values[base + 3] - values[base + 1]) / letterbox.scaleY),
                confidence: values[base + 4], keypoints: points)
        }
    }
}
