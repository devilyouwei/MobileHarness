import Foundation

@MainActor
public final class UIHomeContainer {
    public let conversation = ConversationState()
    public let activity = ActionActivityState()
    public var conversationPresentation: any ConversationPresenting { conversation }
    public var activityPresentation: any ActivityPresenting { activity }
    public var effects: any HomeEffectsPresenting { effectOwner }
    public var expressions: any ExpressionPresenting { expressionOwner }
    private let effectOwner: HomeEffectsWorkflow
    private let expressionOwner: ConversationExpressionPresentation
    private let admission: UIPresentationAdmission
    init(admission: UIPresentationAdmission) {
        self.admission = admission
        conversation.presentationAdmission = admission
        activity.presentationAdmission = admission
        effectOwner = HomeEffectsWorkflow(activity: activity)
        effectOwner.bind(conversation)
        effectOwner.presentationAdmission = admission
        expressionOwner = ConversationExpressionPresentation(state: conversation)
        expressionOwner.presentationAdmission = admission
    }
    public var token: UIPresentationToken { admission.token }
    @discardableResult
    public func present(_ update: ConversationUpdate, token: UIPresentationToken) -> Bool {
        guard admission.acceptsLive(token) else { return false }
        conversation.apply(update)
        return true
    }
    public func presentModelPreparation(_ value: HomeModelPreparation) {
        guard admission.acceptsRetained(), value == .inactive || admission.acceptsLive() else { return }
        conversation.modelPreparation = value
    }
    func invalidate() {
        conversation.modelPreparation = .inactive
        effectOwner.stop()
        expressionOwner.resetExpression()
        conversation.isVoiceActive = false
        conversation.isReplyActive = false
        conversation.listeningAnimationID = nil
        conversation.microphoneSpectrum = [Float](repeating: 0, count: 32)
        conversation.playbackSpectrum = [Float](repeating: 0, count: 32)
        activity.dismissErrorToast(id: activity.errorToast?.id ?? "")
    }
    func stop() async {
        await effectOwner.stopAndWait()
        await activity.stopPresentation()
        conversation.modelPreparation = .inactive
        conversation.isReady = false
        expressionOwner.resetExpression()
    }
}
