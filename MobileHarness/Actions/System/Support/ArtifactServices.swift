import Foundation
import ModelKit
import ModelKitDefaults
import ModelKitHub
import ModelKitRuntime

/// One model-artifact manager preparation, independent of pages and speech scopes.
@MainActor public final class ArtifactServices {
    public let resources: URL
    private var assembly: Task<ModelManager, Error>?
    public init(resources: URL) { self.resources = resources }
    public func manager() async throws -> ModelManager {
        if let assembly { return try await assembly.value }
        let resources = self.resources
        let task = Task {
            guard #available(iOS 27, macOS 27, *) else {
                throw CapabilityError.unavailable("Model artifact management requires OS 27")
            }
            let catalog = try ModelArtifactCatalog.read(
                Bundle.main.bundleURL.appendingPathComponent("Models/model-catalog.json"))
            let storage = try ModelArtifactStorageAdapter(root: resources.deletingLastPathComponent())
            let manager = try await ModelKitDefaults.configureArtifacts(
                resources: resources, catalog: catalog, storage: storage, downloader: HuggingFaceArtifactDownloader())
            _ = try await manager.artifactSnapshots()
            return manager
        }
        assembly = task
        return try await task.value
    }
}
