import Foundation
import Storage

public struct MediaFileRecord: Sendable {
    public let id: String
    public let path: String
    public let bytes: Int
    public let source: String
    public let session: String
    public let input: String
    public let state: String
    public init(id: String, path: String, bytes: Int, source: String, session: String, input: String, state: String) {
        self.id = id
        self.path = path
        self.bytes = bytes
        self.source = source
        self.session = session
        self.input = input
        self.state = state
    }
}

public protocol MediaRepository: Sendable {
    func reserveMedia(bytes: Int, source: String, session: String, input: String, date: Date) async throws
        -> MediaFileRecord
    func media(_ id: String) async throws -> MediaFileRecord?
    func retainedMedia() async throws -> [MediaFileRecord]
    func setMedia(_ id: String, state: String, failure: String?) async throws
}

extension MediaRepository {
    public func setMedia(_ id: String, state: String) async throws {
        try await setMedia(id, state: state, failure: nil)
    }
}
