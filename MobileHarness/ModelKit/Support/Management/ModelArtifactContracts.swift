import Foundation

public enum ModelArtifactError: Error, Sendable {
    case invalidCatalog, invalidEndpoint, missingArtifact, busy, integrity, unsupportedArchive, storage, incompatible
}

public struct ModelDownloadSource: Codable, Sendable, Equatable {
    public static let official = "https://huggingface.co"
    public static let chinaMirror = "https://hf-mirror.com"
    public let endpoint: String
    public let allowsCellular: Bool

    public init(endpoint: String = Self.official, allowsCellular: Bool = false) throws {
        let text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: normalized), components.scheme == "https",
            let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            components.path.isEmpty || components.path == "/", let url = components.url
        else { throw ModelArtifactError.invalidEndpoint }
        self.endpoint = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.allowsCellular = allowsCellular
    }

}

/// Concrete ModelKit download providers implement this port; the artifact store owns publication.
public protocol ModelArtifactDownloader: Sendable {
    func download(
        _ artifact: ModelArtifact, source: ModelDownloadSource, into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

public enum ModelArtifactPhase: String, Codable, Sendable {
    case notInstalled, queued, downloading, verifying, installed, deleting, failed
}

public struct ModelArtifactSnapshot: Sendable {
    public let artifact: ModelArtifact
    public let phase: ModelArtifactPhase
    public let completedBytes: Int64
    public let installedBytes: Int64?
    /// Installation failure, or a transferIndex/removal warning alongside valid installed files.
    public let failure: String?
}

/// ModelKit-owned persistence contract; default disk storage has no dependency on the Storage module.
public protocol ModelArtifactStorage: Sendable {
    func restoreCatalog(defaults: ModelArtifactCatalog) async throws -> ModelArtifactCatalog
    func saveCatalog(_ catalog: ModelArtifactCatalog) async throws
    func restoreTransfers() async throws -> [ModelArtifactTransferRecord]
    func saveTransfers(_ records: [ModelArtifactTransferRecord]) async throws
    func installed(_ artifact: ModelArtifact) async throws -> Bool
    func installedBytes(_ artifact: ModelArtifact) async throws -> Int64?
    func stage(_ artifact: ModelArtifact, task: String) async throws -> URL
    func publish(_ artifact: ModelArtifact, task: String) async throws
    func discard(task: String) async throws
    func remove(_ artifact: ModelArtifact) async throws
}

extension ModelArtifactStorage {
    public func restoreCatalog(defaults: ModelArtifactCatalog) async throws -> ModelArtifactCatalog { defaults }
    public func saveCatalog(_ catalog: ModelArtifactCatalog) async throws { throw ModelArtifactError.storage }
    public func installedBytes(_ artifact: ModelArtifact) async throws -> Int64? { nil }
}

public struct ModelArtifactTransferRecord: Codable, Sendable {
    public let id: String
    public let generation: String
    public let source: ModelDownloadSource
    public init(id: String, generation: String, source: ModelDownloadSource) {
        self.id = id
        self.generation = generation
        self.source = source
    }
}
