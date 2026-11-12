import Foundation

/// A host-bound continuation of an admitted artifact edit, not a model-callable filesystem interface.
public protocol ArtifactStreaming: Sendable {
    /// Close ordinary admission and request cancellation; release is the joined cleanup barrier.
    func revoke(delegateID: String) async
    func append(streamID: String, delegateID: String, text: String) async throws
    func complete(streamID: String, delegateID: String) async throws -> String
    func abort(streamID: String, delegateID: String) async throws
    func snapshot(delegateID: String) async throws -> Data?
    func release(delegateID: String) async throws
}

extension ArtifactStreaming { public func snapshot(delegateID: String) async throws -> Data? { nil } }

/// Facts returned when an edit stream has been admitted.
public struct ArtifactEditPreparation: Codable, Sendable {
    public struct Selection: Codable, Sendable {
        public let start: Int
        public let end: Int
        public let before: String
        public let selected: String
        public let after: String
        public init(start: Int, end: Int, before: String, selected: String, after: String) {
            self.start = start
            self.end = end
            self.before = before
            self.selected = selected
            self.after = after
        }
    }

    public struct RelatedFile: Codable, Sendable {
        public let path: String
        public let version: UInt64
        public let start: Int
        public let end: Int
        public let text: String
        public init(path: String, version: UInt64, start: Int, end: Int, text: String) {
            self.path = path
            self.version = version
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public let streamID: String
    public let path: String
    public let instruction: String
    public let selection: Selection?
    public let projectFiles: [String]
    public let relatedFiles: [RelatedFile]

    public init(
        streamID: String, path: String, instruction: String, selection: Selection? = nil,
        projectFiles: [String] = [], relatedFiles: [RelatedFile] = []
    ) {
        self.streamID = streamID
        self.path = path
        self.instruction = instruction
        self.selection = selection
        self.projectFiles = projectFiles
        self.relatedFiles = relatedFiles
    }
}

/// Shared lexical rules for Writer entry validation and the artifact filesystem boundary.
public enum ArtifactFilePath {
    public static func isFile(_ path: String) -> Bool {
        !path.isEmpty
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
                !part.isEmpty && !part.hasPrefix(".")
                    && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
            }
            && ["html", "css", "js", "svg", "json", "txt", "md"].contains(pathExtension(path))
    }

    public static func isEntry(_ path: String) -> Bool {
        isFile(path) && ["html", "md", "txt"].contains(pathExtension(path))
    }

    private static func pathExtension(_ path: String) -> String {
        (path as NSString).pathExtension.lowercased()
    }
}
