#if os(iOS)
    import Foundation
    import Photos

    /// Native add-only photo import. Callers own admission and join through the OS completion.
    public enum ApplePhotoLibrary {
        public enum Failure: Error { case permissionDenied, invalidImage }
        public static func saveJPEG(_ data: Data) async throws {
            guard data.count <= 4 * 1024 * 1024 else { throw Failure.invalidImage }
            try await savePhoto(data)
        }
        public static func savePhoto(_ data: Data) async throws {
            let info = try await NativeAlbumImage.inspect(data)
            let fileExtension = info.mime == "image/png" ? "png" : info.mime == "image/heic" ? "heic" : "jpg"
            try Task.checkCancellation()
            let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard permission == .authorized || permission == .limited else { throw Failure.permissionDenied }
            // A cancelled permission request must not later issue an album write.
            try Task.checkCancellation()
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "MobileHarness-Photo." + fileExtension
                request.addResource(with: .photo, data: data, options: options)
            }
            // Once committed, report the real effect even if cancellation raced the OS transaction.
        }
    }
#endif
