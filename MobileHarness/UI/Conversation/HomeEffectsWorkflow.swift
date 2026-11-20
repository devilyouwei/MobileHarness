import Foundation

/// Root-owned reply presentation hooks, independent of page lifetime.
@MainActor
public final class HomeEffectsWorkflow: HomeEffectsPresenting {
    var presentationAdmission: UIPresentationAdmission?
    private weak var conversation: ConversationState?
    public init() {}
    public func bind(_ state: ConversationState) { conversation = state }
    public func replyDidBegin() { conversation?.assistantReplyOpacity = 1 }
    public func replyDidFinish() {
        guard presentationAdmission?.acceptsLive() ?? true else { return }
        conversation?.replyWaitingRequest = nil
    }
    public func stop() { replyDidBegin() }
    public func stopAndWait() {
        stop()
        conversation = nil
    }
}

@MainActor
public protocol HomeEffectsPresenting: AnyObject, Sendable {
    func replyDidBegin()
    func replyDidFinish()
    func stop()
}
