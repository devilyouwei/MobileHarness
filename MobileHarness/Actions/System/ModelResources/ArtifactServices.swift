import Foundation
import FunctionContracts
import ModelKitDefaults
import ModelKitHub
import ModelKitRuntime
import StorageFiles

/// Storage/download adaptation only. The model root owns preparation and teardown.
public enum ArtifactServices {
    public static func configuration(files: FilesContainer) throws -> ModelArtifactConfiguration {
        let catalog = try ModelArtifactCatalog.read(
            Bundle.main.bundleURL.appendingPathComponent("Models/model-catalog.json"))
        let storage = try ModelArtifactStorageAdapter(
            files: files.file(files.models),
            index: files.document(
                [ModelArtifactTransferRecord].self, in: files.models, name: "transfers.json", maximumBytes: 262144,
                protection: .afterFirstUnlock))
        return ModelArtifactConfiguration(
            catalog: catalog, storage: storage, downloader: HuggingFaceArtifactDownloader())
    }
}
