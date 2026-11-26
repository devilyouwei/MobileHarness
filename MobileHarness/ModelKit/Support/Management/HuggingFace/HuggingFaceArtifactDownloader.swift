import Foundation
import HuggingFace
import ModelKitRuntime

/// SDK-specific repository download; no model loading, storage publication or settings policy.
public struct HuggingFaceArtifactDownloader: ModelArtifactDownloader {
    public init() {}

    public func download(
        _ artifact: ModelArtifact, source: ModelDownloadSource, into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard artifact.source.kind == .huggingface, let repository = artifact.source.repoId,
            let host = URL(string: source.endpoint), let repo = Repo.ID(rawValue: repository)
        else { throw ModelArtifactError.invalidCatalog }
        let manifest = directory.appendingPathComponent(".hub-plan.json")
        let plan: HubBackgroundTransfer.Plan
        // Resume blobs belong to the exact saved plan, never just to a numeric file index.
        let savedPlan = (try? Data(contentsOf: manifest)).flatMap { data -> HubBackgroundTransfer.Plan? in
            guard data.count <= 8 * 1024 * 1024 else { return nil }
            return try? JSONDecoder().decode(HubBackgroundTransfer.Plan.self, from: data)
        }
        if savedPlan == nil { try? FileManager.default.removeItem(at: directory.appendingPathComponent(".hub-resume")) }
        if let savedPlan, savedPlan.id != artifact.id || savedPlan.revision != artifact.revision {
            for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try FileManager.default.removeItem(at: item)
            }
        } else if let savedPlan, savedPlan.endpoint != source.endpoint {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(".hub-resume"))
        }
        if let savedPlan, savedPlan.id == artifact.id, savedPlan.revision == artifact.revision,
            savedPlan.endpoint == source.endpoint
        {
            plan = savedPlan
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.allowsCellularAccess = source.allowsCellular
            configuration.timeoutIntervalForRequest = 120
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let entries = try await Self.repositoryFiles(
                repo, revision: artifact.revision, host: host, session: session)
            let files = try Self.selectedFiles(entries, patterns: artifact.source.allowPatterns ?? [])
            let members = try files.map { entry -> HubBackgroundTransfer.Member in
                var path = entry.path
                if let prefix = artifact.source.stripPrefix {
                    guard path.hasPrefix(prefix + "/") else { throw ModelArtifactError.invalidCatalog }
                    path = String(path.dropFirst(prefix.count + 1))
                }
                guard ModelArtifactCatalog.validInstalledPath(path) else { throw ModelArtifactError.invalidCatalog }
                let url = host.appendingPathComponent(repository).appendingPathComponent("resolve")
                    .appendingPathComponent(artifact.revision).appendingPathComponent(entry.path)
                return HubBackgroundTransfer.Member(path: path, url: url, bytes: Int64(entry.size ?? 0))
            }
            guard Set(members.map(\.path)).isSuperset(of: artifact.requiredFiles) else {
                throw ModelArtifactError.integrity
            }
            plan = HubBackgroundTransfer.Plan(
                id: artifact.id, revision: artifact.revision, endpoint: source.endpoint, members: members)
            let data = try JSONEncoder().encode(plan)
            guard data.count <= 8 * 1024 * 1024 else { throw ModelArtifactError.invalidCatalog }
            try data.write(to: manifest, options: .atomic)
            #if os(iOS)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: manifest.path)
            #endif
        }
        let transfer = try HubBackgroundTransfer(
            root: directory, plan: plan, allowsCellular: source.allowsCellular, progress: progress)
        try await transfer.run()
    }
    static func repositoryFiles(_ repo: Repo.ID, revision: String, host: URL, session: URLSession) async throws
        -> [Git.TreeEntry]
    {
        let tree = host.appendingPathComponent("api/models").appendingPathComponent(repo.description)
            .appendingPathComponent("tree").appendingPathComponent(revision)
        var url = tree.appending(queryItems: [URLQueryItem(name: "recursive", value: "true")])
        var visited: Set<URL> = []
        var entries: [Git.TreeEntry] = []
        for _ in 0..<64 {
            guard visited.insert(url).inserted else { throw ModelArtifactError.invalidCatalog }
            let (data, response) = try await session.data(from: url)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            guard data.count <= 8 * 1024 * 1024 else { throw ModelArtifactError.invalidCatalog }
            let page = try JSONDecoder().decode([Git.TreeEntry].self, from: data)
            guard page.count <= 16384 - entries.count else { throw ModelArtifactError.invalidCatalog }
            entries.append(contentsOf: page)
            guard let link = response.value(forHTTPHeaderField: "Link"), let next = Self.nextPage(in: link) else {
                return entries
            }
            guard let nextURL = URL(string: next, relativeTo: url)?.absoluteURL,
                nextURL.scheme == tree.scheme, nextURL.host == tree.host, nextURL.port == tree.port,
                nextURL.user == nil, nextURL.password == nil, nextURL.fragment == nil, nextURL.path == tree.path
            else { throw ModelArtifactError.invalidCatalog }
            url = nextURL
        }
        throw ModelArtifactError.invalidCatalog
    }

    private static func nextPage(in header: String) -> String? {
        for link in header.split(separator: ",") {
            let parts = link.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = parts.first, target.hasPrefix("<"), target.hasSuffix(">"),
                parts.dropFirst().contains("rel=\"next\"")
            else { continue }
            return String(target.dropFirst().dropLast())
        }
        return nil
    }

    static func selectedFiles(_ entries: [Git.TreeEntry], patterns: [String]) throws -> [Git.TreeEntry] {
        let files = entries.filter { entry in
            entry.type == .file && (patterns.isEmpty || patterns.contains { fnmatch($0, entry.path, 0) == 0 })
        }
        guard !files.isEmpty, files.count <= 16384 else { throw ModelArtifactError.invalidCatalog }
        var total: Int64 = 0
        for file in files {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.path.hasPrefix("/"), !file.path.contains("\\"),
                components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                let size = file.size, size >= 0, size <= 32 * 1024 * 1024 * 1024,
                total <= 32 * 1024 * 1024 * 1024 - Int64(size)
            else { throw ModelArtifactError.invalidCatalog }
            total += Int64(size)
        }
        return files
    }
}
