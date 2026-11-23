import AgentCore
import Foundation

/// How the Agent listens; the typed value of its `listening` variable.
public enum ListeningMode: String, Sendable, CaseIterable, Equatable {
    /// Capture pauses while the Agent speaks. The fallback when the route cannot cancel echo, or when requested.
    case half
    /// Capture stays open while the Agent speaks, with echo cancellation, so the user can interrupt. The default when
    /// `listening` is unset.
    case full
    /// Wake-word mode: only listens. Speech is judged by a separate channel and the Agent neither replies nor announces.
    case quiet

    public static let `default` = ListeningMode.full

    /// An unset or unrecognized variable reads as the default.
    public init(variable: String?) { self = variable.flatMap(ListeningMode.init(rawValue:)) ?? .default }
}

/// The Assistant-owned control of the `listening` mode. A throwing `apply` rejects the change and leaves the previous
/// mode in force. The remaining requirements carry perception facts, received as Signals, into the same owner.
public protocol ListeningModeControlling: Sendable {
    var mode: ListeningMode { get }
    func apply(_ mode: ListeningMode, source: AgentStateSource, wakeCondition: String?) async throws
    /// An utterance recognized while in `quiet`; it is judged instead of entering the conversation.
    func receiveQuiet(_ text: String, _ input: AgentInput)
    /// A new capture started and has not seen the current mode.
    func republish() async
    /// What the current capture reported about echo cancellation.
    func captureDuplex(_ supported: Bool) async
    /// The perception Agent stopped.
    func perceptionEnded() async
}

extension ListeningModeControlling {
    public func apply(_ mode: ListeningMode, source: AgentStateSource) async throws {
        try await apply(mode, source: source, wakeCondition: nil)
    }
    public var mode: ListeningMode { .default }
    public func receiveQuiet(_ text: String, _ input: AgentInput) {}
    public func republish() async {}
    public func captureDuplex(_ supported: Bool) async {}
    public func perceptionEnded() async {}
}
