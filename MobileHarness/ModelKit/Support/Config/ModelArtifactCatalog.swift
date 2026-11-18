import Foundation

/// Declarative source; Hub resolves its own file URLs and metadata at download time.
public struct ModelArtifactSource: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case huggingface, urlArchive, urlFile }
    public let kind: Kind
    public let repoId: String?
    public let revision: String?
    public let allowPatterns: [String]?
    public let stripPrefix: String?
    public let url: URL?
    public let sha256: String?
}

/// Architecture-specific replacement for a package's source and installed-file contract.
public struct ModelArtifactVariant: Codable, Sendable {
    public let source: ModelArtifactSource
    public let requiredFiles: [String]
    public let estimatedBytes: Int64
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
    public let architectureVariants: [String: ModelArtifactVariant]?
    public var revision: String { source.revision ?? "main" }
    public var installedBytes: Int64 { estimatedBytes }
    public var downloadBytes: Int64 { estimatedBytes }
}

public struct ModelArtifactCatalog: Codable, Sendable {
    public let schemaVersion: Int
    public let packages: [ModelArtifact]
    /// Resolve once before acquisition, so receipts and downloads use the same variant identity.
    public func resolvingArchitecture(_ architecture: String?) throws -> Self {
        let resolved = packages.map { package in
            let variant = architecture.flatMap { package.architectureVariants?[$0] }
            return ModelArtifact(
                id: package.id, name: package.name, capability: package.capability,
                directory: package.directory, source: variant?.source ?? package.source,
                minimumOS: package.minimumOS, requiresPhysicalDevice: package.requiresPhysicalDevice,
                deviceRequirement: package.deviceRequirement, license: package.license,
                requiredFiles: variant?.requiredFiles ?? package.requiredFiles,
                estimatedBytes: variant?.estimatedBytes ?? package.estimatedBytes, architectureVariants: nil)
        }
        return try Self.decode(JSONEncoder().encode(Self(schemaVersion: schemaVersion, packages: resolved)))
    }
    public static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: "model-catalog", withExtension: "json") else {
            throw ModelArtifactError.invalidCatalog
        }
        return try read(url)
    }
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
            case .urlArchive, .urlFile:
                guard let url = source.url, url.scheme == "https", url.host?.isEmpty == false,
                    url.user == nil, url.password == nil, url.fragment == nil,
                    source.repoId == nil, source.allowPatterns == nil, source.stripPrefix == nil,
                    source.kind != .urlArchive || package.estimatedBytes <= 64 * 1024 * 1024,
                    source.kind != .urlFile || package.requiredFiles.count == 1,
                    source.sha256.map(validHash) ?? true
                else { throw ModelArtifactError.invalidCatalog }
            }
        }
        let architectures = Set(value.packages.flatMap { Array(($0.architectureVariants ?? [:]).keys) })
        guard architectures.count <= 16, architectures.allSatisfy(validComponent) else {
            throw ModelArtifactError.invalidCatalog
        }
        for architecture in architectures {
            _ = try value.resolvingArchitecture(architecture)
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
