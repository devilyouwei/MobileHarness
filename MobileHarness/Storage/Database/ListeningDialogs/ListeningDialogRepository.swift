import Foundation
import StorageCore

/// One judgment of the `quiet` exit channel: the latest recognized sentence and what the judge decided.
public struct ListeningDialogRecord: Sendable, Equatable {
    public enum Decision: String, Sendable, Equatable { case stay, exit, error }
    public static let maximumTextBytes = 4096
    public let id: String
    public let sessionID: String
    /// One uninterrupted stay in `quiet`; it begins when the mode is entered.
    public let episodeID: String
    public let text: String
    public let decision: Decision
    public let reason: String?
    /// `local` or `cloud` for the selected Decision source, `literal` for direct matching, nil on failure. Older rows retain historical source values.
    public let modelTier: String?
    public let modelID: String?
    public let latencyMS: Int
    public let error: String?
    public let createdAt: Date
    public init(
        id: String = UUID().uuidString, sessionID: String, episodeID: String, text: String, decision: Decision,
        reason: String? = nil, modelTier: String? = nil, modelID: String? = nil, latencyMS: Int = 0,
        error: String? = nil, createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.episodeID = episodeID
        self.text = text
        self.decision = decision
        self.reason = reason
        self.modelTier = modelTier
        self.modelID = modelID
        self.latencyMS = latencyMS
        self.error = error
        self.createdAt = createdAt
    }
}

/// Append-only trace of `quiet` judgments. Business logic never reads it to decide anything.
public protocol ListeningDialogRepository: Sendable {
    /// Retained rows are bounded; appending beyond the bound drops the oldest whole episodes.
    static var maximumRecords: Int { get }
    func appendListeningDialog(_ record: ListeningDialogRecord) async throws
    func listeningDialogs(episodeID: String) async throws -> [ListeningDialogRecord]
    func recentListeningDialogs(limit: Int) async throws -> [ListeningDialogRecord]
}

extension ListeningDialogRepository {
    public static var maximumRecords: Int { 2000 }
}
