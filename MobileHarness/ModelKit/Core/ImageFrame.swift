import Foundation

/// Upright, unmirrored, tightly packed RGB8 pixels; coordinates start at the top left.
public struct ImageFrame: Sendable {
    public let width: Int
    public let height: Int
    public let rgb: Data
    public init(width: Int, height: Int, rgb: Data) throws {
        guard (1...4096).contains(width), (1...4096).contains(height),
            width * height <= 4_194_304, rgb.count == width * height * 3
        else { throw CapabilityError.invalidRequest("Expected RGB8 image up to 4 megapixels / 4096 pixels per side") }
        self.width = width
        self.height = height
        self.rgb = rgb
    }
}
