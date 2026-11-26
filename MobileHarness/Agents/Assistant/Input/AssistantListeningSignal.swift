import AgentCore
import Foundation
import OSLog

/// The Assistant's current `listening` value, published for the Agents that adapt to it. The mode is owned and
/// judged by the Assistant; subscribers only apply it.
public struct ListeningModeSignal: Codable, Sendable, Equatable {
    public static let contract = "agent.listening.mode.v1"
    public static let channel = "agent.listening"
    public let mode: String

    public init(_ mode: ListeningMode) { self.mode = mode.rawValue }

    func validate() throws {
        guard ListeningMode(rawValue: mode) != nil else { throw CommunicationError.invalidPayload }
    }

    public func message() -> AgentMessage {
        AgentMessage(
            contract: Self.contract, content: self, maximumBytes: 256, validate: { try $0.validate() })
    }
}

extension InputPayload {
    public var listeningMode: ListeningMode? {
        guard case .observation(let message) = self, message.contract == ListeningModeSignal.contract,
            let signal = message.content(as: ListeningModeSignal.self)
        else { return nil }
        return ListeningMode(rawValue: signal.mode)
    }
}

/// Reply activity drives the silence endpoint. Native playback intervals also align onset policy to capture time.
public struct ReplyActivitySignal: Codable, Sendable, Equatable {
    public static let contract = "agent.reply.activity.v1"
    public static let channel = "agent.reply"
    static let maximumBytes = 4096
    public let active: Bool
    public let replyID: UUID?
    public let playback: SpeechPlaybackSnapshot?
    public let continuation: SpeechContinuationProbe?

    public init(
        active: Bool, replyID: UUID? = nil, playback: SpeechPlaybackSnapshot? = nil,
        continuation: SpeechContinuationProbe? = nil
    ) {
        self.active = active
        self.replyID = replyID
        self.playback = playback
        self.continuation = continuation
    }

    func validate() throws {
        guard playback?.isValid ?? true else { throw CommunicationError.invalidPayload }
    }

    public func message() -> AgentMessage {
        AgentMessage(
            contract: Self.contract, content: self, maximumBytes: Self.maximumBytes, validate: { try $0.validate() })
    }
}

extension InputPayload {
    public var replyActivity: Bool? {
        guard case .observation(let message) = self, message.contract == ReplyActivitySignal.contract else {
            return nil
        }
        return message.content(as: ReplyActivitySignal.self)?.active
    }
}

extension AssistantChatWorker {
    /// Publishes the current mode for subscribers; admission by Gateway is the only result, and nobody may be
    /// subscribed yet because Signals are not replayed.
    func publishListeningMode(_ mode: ListeningMode) async throws {
        guard let messaging, let speechSessionID else { return }
        let parent = AgentInput(id: UUID().uuidString, sessionID: speechSessionID, payload: .event("listening.mode"))
        try await messaging.publish(ListeningModeSignal(mode).message(), parent: parent)
    }
}

extension AssistantChatWorker {
    /// Recomputes reply activity and publishes it when it changed. Concurrent triggers coalesce into one loop so the
    /// last published value always reflects the latest state.
    func refreshReplyActivity(force: Bool = false) async {
        if force { publishedReplyActivity = nil }
        guard let messaging, let speechSessionID else { return }
        if replyActivityRefreshing {
            replyActivityDirty = true
            return
        }
        replyActivityRefreshing = true
        defer { replyActivityRefreshing = false }
        repeat {
            replyActivityDirty = false
            let active = await hasActiveReply(sessionID: speechSessionID)
            let playback = await speechOutput?.playbackSnapshot(sessionID: speechSessionID) ?? .init()
            let target = active && decisionTurn?.sessionID == speechSessionID ? decisionTurn?.id : nil
            let activity = ReplyActivitySignal(
                active: active, replyID: target, playback: playback, continuation: speechContinuationProbe)
            guard activity != publishedReplyActivity else { continue }
            publishedReplyActivity = activity
            let parent = AgentInput(
                id: UUID().uuidString, sessionID: speechSessionID, payload: .event("reply.activity"))
            do { try await messaging.publish(activity.message(), parent: parent) } catch {
                publishedReplyActivity = nil
                Logger(subsystem: "dev.mobileharness", category: "AssistantSpeech").error(
                    "reply activity not published: \(String(describing: error), privacy: .public)")
            }
        } while replyActivityDirty
    }

    func scheduleReplyActivityRefresh() {
        Task { await refreshReplyActivity() }
    }
}
