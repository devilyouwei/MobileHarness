import CoreGraphics
import Foundation
import ImageIO

/// Generic native image preparation. The caller owns upload/storage policy and lifetime.
public enum NativeImageCompression {
    public struct InputLimits: Sendable {
        public let maximumBytes: Int
        public let maximumDimension: Int
        public let maximumPixels: Int
        public init(
            maximumBytes: Int = 4 * 1024 * 1024, maximumDimension: Int = 65535,
            maximumPixels: Int = 268_435_456
        ) {
            self.maximumBytes = maximumBytes
            self.maximumDimension = maximumDimension
            self.maximumPixels = maximumPixels
        }
    }
    public struct Limits: Sendable {
        public let maximumDimension: Int
        public let maximumPixels: Int
        public let maximumBytes: Int
        public let quality: Double

        public init(maximumDimension: Int, maximumPixels: Int, maximumBytes: Int, quality: Double = 0.82) {
            self.maximumDimension = maximumDimension
            self.maximumPixels = maximumPixels
            self.maximumBytes = maximumBytes
            self.quality = quality
        }
    }

    public enum Failure: Error, Equatable {
        case invalidLimits, invalidImage, unsupportedImage, encodingFailed, sizeBudgetExceeded
    }

    /// Uses a joined native worker so callers on MainActor do not decode or encode images there.
    public static func jpeg(from data: Data, limits: Limits, inputLimits: InputLimits = InputLimits()) async throws
        -> Data
    {
        try Task.checkCancellation()
        let worker = Task.detached(priority: Task.currentPriority) {
            try autoreleasepool { try encode(data, limits: limits, inputLimits: inputLimits) }
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    /// Camera output is trusted encoded JPEG, but its native byte size is scene-dependent.
    static func cameraPhotoJPEG(from data: Data) async throws -> Data {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= 32 * 1024 * 1024 else { throw Failure.invalidImage }
        if data.count <= 4 * 1024 * 1024 { return data }
        return try await jpeg(
            from: data,
            limits: .init(
                maximumDimension: 4096, maximumPixels: 16_777_216, maximumBytes: 4 * 1024 * 1024, quality: 0.85),
            inputLimits: .init(maximumBytes: 32 * 1024 * 1024, maximumDimension: 4096, maximumPixels: 16_777_216))
    }

    private static func encode(_ data: Data, limits: Limits, inputLimits: InputLimits) throws -> Data {
        try Task.checkCancellation()
        guard (1...4096).contains(limits.maximumDimension), (1...16_777_216).contains(limits.maximumPixels),
            (1024...4 * 1024 * 1024).contains(limits.maximumBytes),
            limits.quality.isFinite, (0.5...1).contains(limits.quality),
            (1...32 * 1024 * 1024).contains(inputLimits.maximumBytes),
            (1...65535).contains(inputLimits.maximumDimension), (1...268_435_456).contains(inputLimits.maximumPixels)
        else { throw Failure.invalidLimits }
        guard !data.isEmpty, data.count <= inputLimits.maximumBytes,
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            (1...inputLimits.maximumDimension).contains(width), (1...inputLimits.maximumDimension).contains(height),
            Double(width) * Double(height) <= Double(inputLimits.maximumPixels)
        else { throw Failure.invalidImage }
        guard let type = CGImageSourceGetType(source), ["public.jpeg", "public.png"].contains(type as String) else {
            throw Failure.unsupportedImage
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard (1...8).contains(orientation) else { throw Failure.invalidImage }
        let longest = max(width, height)
        let pixels = Double(width) * Double(height)
        if type as String == "public.jpeg", orientation == 1,
            longest <= limits.maximumDimension, pixels <= Double(limits.maximumPixels),
            data.count <= limits.maximumBytes
        {
            try Task.checkCancellation()
            return data
        }
        let scale = min(
            1, Double(limits.maximumDimension) / Double(longest), sqrt(Double(limits.maximumPixels) / pixels))
        var dimension = max(1, Int(floor(Double(longest) * scale)))
        let qualities = [limits.quality, min(limits.quality, 0.65), min(limits.quality, 0.5)]
        for _ in 0..<4 {
            try Task.checkCancellation()
            let encoded: Data? = try autoreleasepool {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: dimension,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    throw Failure.invalidImage
                }
                guard max(image.width, image.height) <= limits.maximumDimension,
                    image.width * image.height <= limits.maximumPixels
                else { return nil }
                for (index, quality) in qualities.enumerated() {
                    if index > 0, quality == qualities[index - 1] { continue }
                    try Task.checkCancellation()
                    let output = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)
                    else { throw Failure.encodingFailed }
                    CGImageDestinationAddImage(
                        destination, image,
                        [
                            kCGImageDestinationLossyCompressionQuality: quality,
                            kCGImageDestinationEmbedThumbnail: false,
                            kCGImageDestinationBackgroundColor: CGColor(gray: 1, alpha: 1),
                        ] as CFDictionary)
                    guard CGImageDestinationFinalize(destination), output.length > 0 else {
                        throw Failure.encodingFailed
                    }
                    try Task.checkCancellation()
                    if output.length <= limits.maximumBytes { return output as Data }
                }
                return nil
            }
            if let encoded { return encoded }
            let smaller = max(1, Int(Double(dimension) * 0.75))
            guard smaller < dimension else { break }
            dimension = smaller
        }
        throw Failure.sizeBudgetExceeded
    }
}
