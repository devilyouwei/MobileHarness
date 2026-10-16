import FactoryKit
import Foundation
import Storage
import StorageCache
import StorageDatabase
import StorageFiles
import StorageSQLite
import StorageState

/// Instance-local registration; the App owns asynchronous startup and shutdown explicitly.
public final class ApplicationContainer: ManagedContainer, @unchecked Sendable {
    public let manager = ContainerManager()
    private let root: URL
    public init(root: URL) { self.root = root }
    public var storage: Factory<StorageContainer> {
        self {
            let files = FilesContainer(
                settings: self.root.appendingPathComponent("Settings", isDirectory: true),
                photos: self.root.appendingPathComponent("CapturedPhotos", isDirectory: true),
                models: self.root.appendingPathComponent("Models", isDirectory: true))
            return StorageContainer(
                database: SQLiteDatabaseFactory.make(databaseURL: self.root.appendingPathComponent("records.sqlite")),
                files: files)
        }.cached
    }
    public var state: Factory<StateContainer> { self { self.storage().state } }
    public var cache: Factory<CacheContainer> { self { self.storage().cache } }
    public var files: Factory<FilesContainer> { self { self.storage().files } }
    public var database: Factory<any DatabaseStorage> { self { self.storage().database } }
}
