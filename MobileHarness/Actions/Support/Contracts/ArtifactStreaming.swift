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
