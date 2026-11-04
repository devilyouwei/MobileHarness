import Foundation

/// A host-bound continuation of an admitted artifact edit, not a model-callable filesystem interface.
public protocol ArtifactStreaming: Sendable {
    func append(streamID: String, taskID: String, text: String) async throws
    func complete(streamID: String, taskID: String) async throws -> String
    func abort(streamID: String, taskID: String) async throws
    func snapshot(taskID: String) async throws -> Data?
    func release(taskID: String) async throws
}

extension ArtifactStreaming { public func snapshot(taskID: String) async throws -> Data? { nil } }
