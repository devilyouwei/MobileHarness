import Foundation
import Storage
import StorageMedia

public enum CameraStorageFactory {
    public static func make(repository: Result<any MediaRepository, any Error>, root: URL) -> CapturedPhotoStore {
        CapturedPhotoStore(
            repository: repository,
            files: Result { try LocalFileStore(root: root, protection: .afterFirstUnlock) as any BinaryObjectStore },
            limits: .init(maximumPhotos: 1024, maximumBytes: 2 * 1024 * 1024 * 1024, overflowPolicy: .evictOldest))
    }
}
