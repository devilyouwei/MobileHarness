import Accelerate
import CoreVideo
import Foundation
import ModelKitCoreML

/// One authoritative rounded aspect-fit layout for image preparation and coordinate restoration.
public struct YOLOImageLayout: Sendable, Equatable {
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let width: Int
    public let height: Int
    public let left: Int
    public let top: Int
    public let offsetX: Float
    public let offsetY: Float
    public let scaleX: Float
    public let scaleY: Float

    public init(width: Int, height: Int, visionScaleFit: Bool = false) throws {
        guard (1...4096).contains(width), (1...4096).contains(height), width * height <= 4_194_304 else {
            throw CoreMLGraphError.invalidTensor("Image dimensions")
        }
        sourceWidth = width
        sourceHeight = height
        let scale = min(640.0 / Double(width), 640.0 / Double(height))
        self.width = max(1, Int((Double(width) * scale).rounded()))
        self.height = max(1, Int((Double(height) * scale).rounded()))
        left = (640 - self.width) / 2
        top = (640 - self.height) / 2
        scaleX = visionScaleFit ? Float(scale) : Float(self.width) / Float(width)
        scaleY = visionScaleFit ? Float(scale) : Float(self.height) / Float(height)
        offsetX = visionScaleFit ? (640 - Float(width) * scaleX) / 2 : Float(left)
        offsetY = visionScaleFit ? (640 - Float(height) * scaleY) / 2 : Float(top)
    }
}

/// Confined to YOLOImageGraph. One reusable output and at most one source-sized scratch buffer.
/// The returned buffer is borrowed until the next call; prediction is synchronous on the same actor.
final class YOLOImagePreparation {
    private var pixels: CVPixelBuffer?
    private var previousLayout: YOLOImageLayout?
    private var scratch = [UInt8]()

    func prepare(rgb: Data, layout: YOLOImageLayout) throws -> CVPixelBuffer {
        guard rgb.count == layout.sourceWidth * layout.sourceHeight * 3 else {
            throw CoreMLGraphError.invalidTensor("RGB size")
        }
        if pixels == nil {
            var buffer: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            guard
                CVPixelBufferCreate(
                    kCFAllocatorDefault, 640, 640, kCVPixelFormatType_32BGRA, attributes, &buffer
                ) == kCVReturnSuccess, let buffer
            else {
                throw CoreMLGraphError.invalidTensor("Pixel buffer allocation")
            }
            pixels = buffer
        }
        guard let pixels, CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess else {
            throw CoreMLGraphError.invalidTensor("Pixel buffer lock")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else {
            throw CoreMLGraphError.invalidTensor("Pixel buffer storage")
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        if previousLayout != layout {
            // Refill on geometry changes so old content cannot leak into newly exposed padding.
            let row: [UInt8] = Array(repeating: [114, 114, 114, 255], count: 640).flatMap { $0 }
            row.withUnsafeBytes { bytes in
                for y in 0..<640 {
                    base.advanced(by: y * rowBytes).copyMemory(from: bytes.baseAddress!, byteCount: 2560)
                }
            }
        }
        var destination = vImage_Buffer(
            data: base.advanced(by: layout.top * rowBytes + layout.left * 4),
            height: vImagePixelCount(layout.height), width: vImagePixelCount(layout.width), rowBytes: rowBytes)
        try rgb.withUnsafeBytes { bytes in
            var source = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: bytes.baseAddress!),
                height: vImagePixelCount(layout.sourceHeight), width: vImagePixelCount(layout.sourceWidth),
                rowBytes: layout.sourceWidth * 3)
            if layout.width == layout.sourceWidth && layout.height == layout.sourceHeight {
                // Camera already supplies a 640-long-edge image: convert directly into the letterbox ROI.
                try check(
                    vImageConvert_RGB888toBGRA8888(&source, nil, 255, &destination, false, vImage_Flags(kvImageNoFlags))
                )
            } else {
                let count = layout.sourceWidth * layout.sourceHeight * 4
                if scratch.count != count { scratch = [UInt8](repeating: 0, count: count) }
                try scratch.withUnsafeMutableBytes { storage in
                    var intermediate = vImage_Buffer(
                        data: storage.baseAddress!, height: source.height, width: source.width,
                        rowBytes: layout.sourceWidth * 4)
                    try check(
                        vImageConvert_RGB888toBGRA8888(
                            &source, nil, 255, &intermediate, false, vImage_Flags(kvImageNoFlags)))
                    try check(vImageScale_ARGB8888(&intermediate, &destination, nil, vImage_Flags(kvImageNoFlags)))
                }
            }
        }
        previousLayout = layout
        return pixels
    }
}

private func check(_ error: vImage_Error) throws {
    guard error == kvImageNoError else { throw CoreMLGraphError.invalidTensor("vImage error \(error)") }
}
