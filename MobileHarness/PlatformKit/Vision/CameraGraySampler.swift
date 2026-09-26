import Foundation

/// Small orientation-aware grayscale sample; no full-frame RGB materialization.
enum CameraGraySampler {
    static func sample(
        base: UnsafeMutableRawPointer, sourceWidth: Int, sourceHeight: Int,
        stride: Int, rotation: Int
    ) throws -> Data {
        guard (1...4096).contains(sourceWidth), (1...4096).contains(sourceHeight),
            sourceWidth * sourceHeight <= 4_194_304, stride >= sourceWidth * 4, (0...3).contains(rotation)
        else { throw SampleError.invalidBuffer }
        let width = rotation % 2 == 0 ? sourceWidth : sourceHeight
        let height = rotation % 2 == 0 ? sourceHeight : sourceWidth
        let source = base.assumingMemoryBound(to: UInt8.self)
        var gray = Data(count: 4096)
        gray.withUnsafeMutableBytes { bytes in
            let destination = bytes.bindMemory(to: UInt8.self)
            for y in 0..<64 {
                let uy = min(height - 1, (2 * y + 1) * height / 128)
                for x in 0..<64 {
                    let ux = min(width - 1, (2 * x + 1) * width / 128)
                    let sx: Int
                    let sy: Int
                    switch rotation {
                    case 1:
                        sx = uy
                        sy = sourceHeight - 1 - ux
                    case 2:
                        sx = sourceWidth - 1 - ux
                        sy = sourceHeight - 1 - uy
                    case 3:
                        sx = sourceWidth - 1 - uy
                        sy = ux
                    default:
                        sx = ux
                        sy = uy
                    }
                    let i = sy * stride + sx * 4
                    destination[y * 64 + x] = UInt8(
                        (77 * Int(source[i + 2]) + 150 * Int(source[i + 1]) + 29 * Int(source[i]) + 128) >> 8)
                }
            }
        }
        return gray
    }
    enum SampleError: Error { case invalidBuffer }
}
