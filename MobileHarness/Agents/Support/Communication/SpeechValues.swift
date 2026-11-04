import AgentCore
import Foundation
import StorageCore

public enum SpeechValidationError: Error, Equatable, Sendable { case invalidRequest }

public enum SpeechPhase: String, Codable, Sendable { case listening, speaking, processing, empty }

/// A synthesis unit selected by its originating Agent; audio IDs are application-generated.
public struct SpeechSynthesisInput: Codable, Sendable, Equatable {
    public let audioID: String
    public let text: String
    public let locale: String
    public init(audioID: String? = nil, text: String, locale: String = "auto") throws {
        self.audioID = audioID ?? UUID().uuidString
        self.text = text
        self.locale = locale
        try validate()
    }
    public func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            text.utf8.count <= 2000, ["auto", "zh-CN", "en-US"].contains(locale)
        else { throw SpeechValidationError.invalidRequest }
    }
}

/// Complete reply occupancy and authenticated Assistant report completion facts.
/// SpeechPerception alone decides whether a completed report should enable listening.
public struct ReplyActivity: Codable, Sendable {
    public static let contract = "interaction.replyActivity"
    public let revision: UInt64
    public let inputs: [String]
    public let tasks: [String]
    public let acknowledgedRoot: String
    public let completedReportID: String?
    public let reportStartedAt: TimeInterval?
    public init(
        revision: UInt64, inputs: [String], tasks: [String], acknowledgedRoot: String,
        completedReportID: String? = nil, reportStartedAt: TimeInterval? = nil
    ) {
        self.revision = revision
        self.inputs = inputs
        self.tasks = tasks
        self.acknowledgedRoot = acknowledgedRoot
        self.completedReportID = completedReportID
        self.reportStartedAt = reportStartedAt
    }
    public func validate() throws {
        guard revision > 0, inputs.count <= 128, tasks.count <= 128,
            Set(inputs).count == inputs.count, Set(tasks).count == tasks.count,
            (completedReportID == nil && reportStartedAt == nil)
                || (completedReportID != nil && reportStartedAt.map({ $0.isFinite && $0 > 0 }) == true),
            completedReportID.map({ !$0.isEmpty && $0.utf8.count <= 128 && !inputs.contains($0) }) ?? true
        else { throw CommunicationError.invalidPayload }
    }
    public var message: AgentMessage {
        AgentMessage(contract: Self.contract, content: self, maximumBytes: 16384, validate: { try $0.validate() })
    }
}
