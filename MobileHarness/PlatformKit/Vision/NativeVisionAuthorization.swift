import Foundation

#if os(iOS)
    import AVFoundation
    import Photos
#endif

/// Queries only. Reading authorization never opens a device, picker or permission prompt.
@MainActor enum NativeVisionAuthorization {
    static func snapshot() -> [String: String] {
        #if os(iOS)
            let camera: String
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined: camera = "notDetermined"
            case .restricted: camera = "restricted"
            case .denied: camera = "denied"
            case .authorized: camera = "authorized"
            @unknown default: camera = "unknown"
            }
            func photo(_ access: PHAccessLevel) -> String {
                switch PHPhotoLibrary.authorizationStatus(for: access) {
                case .notDetermined: "notDetermined"
                case .restricted: "restricted"
                case .denied: "denied"
                case .authorized: "authorized"
                case .limited: "limited"
                @unknown default: "unknown"
                }
            }
            return ["camera": camera, "photosAddOnly": photo(.addOnly), "photosReadWrite": photo(.readWrite)]
        #else
            return ["camera": "unsupported", "photosAddOnly": "unsupported", "photosReadWrite": "unsupported"]
        #endif
    }
}
