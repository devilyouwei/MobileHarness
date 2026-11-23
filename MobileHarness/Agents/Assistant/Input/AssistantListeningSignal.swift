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

/// Whether the Assistant has reply work or playback in the speech session. SpeechPerception only caches it to choose
/// its silence endpoint; the Assistant remains the sole owner of the fact.
public struct ReplyActivitySignal: Codable, Sendable, Equatable {
    public static let contract = "agent.reply.activity.v1"
    public static let channel = "agent.reply"
    public let active: Bool

    public init(active: Bool) { self.active = active }

    public func message() -> AgentMessage {
        AgentMessage(contract: Self.contract, content: self, maximumBytes: 256, validate: { _ in })
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
            guard active != publishedReplyActivity else { continue }
            publishedReplyActivity = active
            let parent = AgentInput(
                id: UUID().uuidString, sessionID: speechSessionID, payload: .event("reply.activity"))
            do { try await messaging.publish(ReplyActivitySignal(active: active).message(), parent: parent) } catch {
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
