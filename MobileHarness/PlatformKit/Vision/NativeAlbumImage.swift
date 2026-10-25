import Foundation

public struct NativePhotoInfo: Sendable {
    public let mime: String
    public let width: Int
    public let height: Int
    public let capturedAt: Date?
}
public enum NativePhotoFailure: Error, Sendable { case invalidImage }

#if canImport(ImageIO)
    import ImageIO
    import UniformTypeIdentifiers

    public enum NativeAlbumImage {
        public static func inspect(_ data: Data) async throws -> NativePhotoInfo {
            let task = Task.detached {
                try Task.checkCancellation()
                guard !data.isEmpty, data.count <= 32 * 1024 * 1024,
                    let source = CGImageSourceCreateWithData(
                        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                    CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
                    let type = CGImageSourceGetType(source) as String?,
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                    let width = properties[kCGImagePropertyPixelWidth] as? Int,
                    let height = properties[kCGImagePropertyPixelHeight] as? Int,
                    width > 0, height > 0, width <= 100_000, height <= 100_000,
                    Int64(width) * Int64(height) <= 100_000_000
                else { throw NativePhotoFailure.invalidImage }
                let mime: String
                switch type {
                case UTType.jpeg.identifier: mime = "image/jpeg"
                case UTType.png.identifier: mime = "image/png"
                case UTType.heic.identifier: mime = "image/heic"
                default: throw NativePhotoFailure.invalidImage
                }
                let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
                var date: Date?
                if let text = exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                    let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
                {
                    let format = DateFormatter()
                    format.locale = Locale(identifier: "en_US_POSIX")
                    format.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
                    date = format.date(from: text + offset)
                }
                try Task.checkCancellation()
                return NativePhotoInfo(mime: mime, width: width, height: height, capturedAt: date)
            }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
        public static func thumbnail(_ data: Data, maximumDimension: Int = 360) async throws -> Data {
            let task = Task.detached {
                try Task.checkCancellation()
                guard (1...2048).contains(maximumDimension), data.count <= 32 * 1024 * 1024,
                    let source = CGImageSourceCreateWithData(
                        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                    let image = CGImageSourceCreateThumbnailAtIndex(
                        source, 0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                            kCGImageSourceShouldCacheImmediately: true,
                        ] as CFDictionary)
                else { throw NativePhotoFailure.invalidImage }
                let output = NSMutableData()
                guard
                    let destination = CGImageDestinationCreateWithData(
                        output, UTType.jpeg.identifier as CFString, 1, nil)
                else { throw NativePhotoFailure.invalidImage }
                CGImageDestinationAddImage(
                    destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                guard CGImageDestinationFinalize(destination), output.length <= 4 * 1024 * 1024 else {
                    throw NativePhotoFailure.invalidImage
                }
                try Task.checkCancellation()
                return output as Data
            }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }
#endif
