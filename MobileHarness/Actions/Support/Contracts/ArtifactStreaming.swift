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
