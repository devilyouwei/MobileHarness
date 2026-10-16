import Foundation
import ModelKit
import ModelKitDefaults
import ModelKitHub
import ModelKitRuntime
import StorageFiles

/// One model-artifact manager preparation, independent of pages and speech scopes.
@MainActor public final class ArtifactServices {
    public let resources: URL
    private var preparedManager: ModelManager?
    private var closed = false
    private var shutdown: Task<Void, any Error>?
    private var assembly: Task<ModelManager, Error>?
    private let files: FilesContainer
    public init(resources: URL, files: FilesContainer) {
        self.resources = resources
        self.files = files
    }
    public func manager() async throws -> ModelManager {
        guard !closed else { throw CapabilityError.sessionClosed }
        if let assembly { return try await assembly.value }
        let resources = self.resources
        let files = self.files
        let task = Task {
            guard #available(iOS 27, macOS 27, *) else {
                throw CapabilityError.unavailable("Model artifact management requires OS 27")
            }
            let catalog = try ModelArtifactCatalog.read(
                Bundle.main.bundleURL.appendingPathComponent("Models/model-catalog.json"))
            let storage = try ModelArtifactStorageAdapter(
                files: files.file(files.models),
                index: files.document(
                    [ModelArtifactTransferRecord].self, in: files.models, name: "transfers.json", maximumBytes: 262144,
                    protection: .afterFirstUnlock))
            let manager = try await ModelKitDefaults.configureArtifacts(
                resources: resources, catalog: catalog, storage: storage, downloader: HuggingFaceArtifactDownloader())
            self.preparedManager = manager
            _ = try await manager.artifactSnapshots()
            return manager
        }
        assembly = task
        return try await task.value
    }
    public func prepareBackground() async throws { _ = try await manager() }
    public func stop() async throws {
        if let shutdown { return try await shutdown.value }
        closed = true
        let task = Task { [self, assembly] in
            if let assembly { _ = await assembly.result }
            try await preparedManager?.releaseArtifacts()
        }
        shutdown = task
        try await task.value
    }

}
