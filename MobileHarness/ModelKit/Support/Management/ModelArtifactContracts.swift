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

/// Declarative source; Hub resolves its own file URLs and metadata at download time.
public struct ModelArtifactSource: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case huggingface, urlArchive }
    public let kind: Kind
    public let repoId: String?
    public let revision: String?
    public let allowPatterns: [String]?
    public let stripPrefix: String?
    public let url: URL?
    public let sha256: String?
}

public struct ModelArtifact: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let capability: String
    public let directory: String
    public let source: ModelArtifactSource
    public let minimumOS: Int
    public let requiresPhysicalDevice: Bool
    public let deviceRequirement: String?
    public let license: String
    public let requiredFiles: [String]
    /// Display/storage estimate only; not an integrity assertion.
    public let estimatedBytes: Int64
    public var revision: String { source.revision ?? "main" }
    public var installedBytes: Int64 { estimatedBytes }
    public var downloadBytes: Int64 { estimatedBytes }
}

/// Concrete SDKs implement this outside Management; publication remains owned by the store.
public protocol ModelArtifactDownloader: Sendable {
    func download(
        _ artifact: ModelArtifact, source: ModelDownloadSource, into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

public struct ModelArtifactCatalog: Codable, Sendable {
    public let schemaVersion: Int
    public let packages: [ModelArtifact]
    public static func read(_ url: URL) throws -> Self {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        return try decode(data)
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw ModelArtifactError.invalidCatalog }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 2, !value.packages.isEmpty, value.packages.count <= 32,
            Set(value.packages.map(\.id)).count == value.packages.count,
            Set(value.packages.map(\.directory)).count == value.packages.count
        else { throw ModelArtifactError.invalidCatalog }
        for package in value.packages {
            guard validComponent(package.id), validComponent(package.directory),
                ProvidedCapability(rawValue: package.capability) != nil, package.minimumOS > 0,
                !package.license.isEmpty, !package.requiredFiles.isEmpty, package.requiredFiles.count <= 4096,
                package.requiredFiles.allSatisfy(validPath),
                Set(package.requiredFiles).count == package.requiredFiles.count,
                package.estimatedBytes > 0, package.estimatedBytes <= 32 * 1024 * 1024 * 1024
            else { throw ModelArtifactError.invalidCatalog }
            let source = package.source
            if let revision = source.revision {
                guard validPath(revision) else { throw ModelArtifactError.invalidCatalog }
            }
            switch source.kind {
            case .huggingface:
                guard let repo = source.repoId, repo.split(separator: "/").count == 2, validPath(repo),
                    let patterns = source.allowPatterns, !patterns.isEmpty, patterns.count <= 128,
                    patterns.allSatisfy({
                        !$0.isEmpty && $0.count <= 512 && !$0.hasPrefix("/") && !$0.contains("..") && !$0.contains("\\")
                    }),
                    source.url == nil, source.sha256 == nil
                else { throw ModelArtifactError.invalidCatalog }
                if let prefix = source.stripPrefix {
                    guard validPath(prefix), patterns.allSatisfy({ $0.hasPrefix(prefix + "/") }) else {
                        throw ModelArtifactError.invalidCatalog
                    }
                }
            case .urlArchive:
                guard let url = source.url, url.scheme == "https", url.user == nil, url.password == nil,
                    source.repoId == nil, source.allowPatterns == nil, source.stripPrefix == nil,
                    package.estimatedBytes <= 64 * 1024 * 1024,
                    source.sha256.map(validHash) ?? true
                else { throw ModelArtifactError.invalidCatalog }
            }
        }
        return value
    }
    private static let componentCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    static func validComponent(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 200 && text != "." && text != ".."
            && text.unicodeScalars.allSatisfy {
                componentCharacters.contains($0)
            }
    }
    public static func validInstalledPath(_ text: String) -> Bool { validPath(text) }
    static func validPath(_ text: String) -> Bool {
        !text.hasPrefix("/") && !text.contains("\\")
            && text.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { validComponent(String($0)) }
    }
    static func validHash(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { "0123456789abcdef".contains($0) }
    }
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

/// Generic operations injected by App; Runtime has no Storage dependency.
public protocol ModelArtifactStorage: Sendable {
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
