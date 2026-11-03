import Foundation
import ImageIO

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

/// Display-only window identity. Images are supplied as bytes, never paths or URLs.
public enum WindowIcon: Equatable, Sendable {
    case system(name: String)
    case emoji(String)
    case image(Data)

    @MainActor func prepared() throws -> Self {
        switch self {
        case .system(let name):
            guard !name.isEmpty, name.utf8.count <= 128 else { throw WindowError.invalidIcon }
            #if os(iOS)
                guard UIImage(systemName: name) != nil else { throw WindowError.invalidIcon }
            #elseif os(macOS)
                guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
                    throw WindowError.invalidIcon
                }
            #endif
            return self
        case .emoji(let value):
            guard value.count == 1, value.utf8.count <= 64,
                value.unicodeScalars.contains(where: { $0.properties.isEmoji }),
                value.unicodeScalars.count > 1
                    || value.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation })
            else { throw WindowError.invalidIcon }
            return self
        case .image(let data):
            guard !data.isEmpty, data.count <= 1024 * 1024,
                let source = CGImageSourceCreateWithData(
                    data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                (1...4096).contains(width), (1...4096).contains(height),
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 96,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary)
            else { throw WindowError.invalidIcon }
            let result = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil) else {
                throw WindowError.invalidIcon
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw WindowError.invalidIcon }
            return .image(result as Data)
        }
    }
}

@MainActor enum WindowCardLayout {
    static let minimumWidth = 128.0
    static let maximumWidth = 320.0
    static let controlWidth = 44.0
    static let titlePadding = 8.0
    static let defaultTitleSize = 15.0

    static func titleWidth(_ title: String, fontSize: Double) -> Double {
        #if os(iOS)
            let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        #elseif os(macOS)
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        #endif
        return ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }

    static func width(title: String, viewport: Double, fontSize: Double) -> Double {
        let limit = min(maximumWidth, max(1, viewport - 32))
        return min(limit, max(minimumWidth, titleWidth(title, fontSize: fontSize) + 2 * (controlWidth + titlePadding)))
    }
}
