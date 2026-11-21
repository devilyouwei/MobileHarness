import Foundation
import FunctionContracts
import StorageCore
import StorageFiles
import StorageMedia

public enum CameraStorageFactory {
    public static func make(
        repository: @escaping @Sendable () throws -> any MediaRepository,
        files: @escaping @Sendable () throws -> any FileStore
    )
        -> MediaStore
    {
        MediaStore(
            repository: repository,
            files: files,
            limits: .init(maximumPhotos: 1024, maximumBytes: 2 * 1024 * 1024 * 1024, overflowPolicy: .evictOldest))
    }
}
