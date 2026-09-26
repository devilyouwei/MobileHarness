import CoreVideo
import Foundation

/// Upright RGB8 or retained native BGRA with orientation; width/height describe upright coordinates.
public struct ImageFrame: Sendable {
    public let width: Int
    public let height: Int
    public let rgb: Data?
    public let native: NativeImageBuffer?
    public init(width: Int, height: Int, rgb: Data) throws {
        guard (1...4096).contains(width), (1...4096).contains(height),
            width * height <= 4_194_304, rgb.count == width * height * 3
        else { throw CapabilityError.invalidRequest("Expected RGB8 image up to 4 megapixels / 4096 pixels per side") }
        self.width = width
        self.height = height
        self.rgb = rgb
        self.native = nil
    }
    public init(pixelBuffer: CVPixelBuffer, rotation: Int) throws {
        let native = try NativeImageBuffer(pixelBuffer: pixelBuffer, rotation: rotation)
        self.native = native
        width = native.width
        height = native.height
        rgb = nil
    }

}

/// Retains a read-only producer-owned frame. Producer must not mutate/reuse pixels while retained.
/// Native storage stays inside synchronous adapter access; no mutable pointer is exposed.
public final class NativeImageBuffer: @unchecked Sendable {
    private let pixels: CVPixelBuffer
    public let rotation: Int
    public let width: Int
    public let height: Int
    public init(pixelBuffer: CVPixelBuffer, rotation: Int) throws {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard (1...4096).contains(w), (1...4096).contains(h), w * h <= 4_194_304,
            (0...3).contains(rotation), CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
        else { throw CapabilityError.invalidRequest("Expected bounded BGRA pixel buffer") }
        pixels = pixelBuffer
        self.rotation = rotation
        width = rotation % 2 == 0 ? w : h
        height = rotation % 2 == 0 ? h : w
    }
    public func withPixelBuffer<T>(_ body: (CVPixelBuffer) throws -> T) rethrows -> T { try body(pixels) }
}
