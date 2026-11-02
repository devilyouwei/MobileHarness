import Foundation

@MainActor
public final class UIHomeContainer {
    public func stateSnapshot() async throws -> UIStateSnapshot {
        try Task.checkCancellation()
        return UIStateSnapshot(
            path: "ui.home",
            business: [
                "voicePhase": .text(conversation.voicePhase.rawValue), "voiceActive": .flag(conversation.isVoiceActive),
                "replyActive": .flag(conversation.isReplyActive),
            ], runtime: ["available": .flag(admission.active), "ready": .flag(conversation.isReady)],
            children: [.init(path: "ui.home.expression")],
            stateValues: ["business.voicePhase": VoicePhase.allCases.map(\.rawValue)])
    }
    public func stateReaders() async throws -> [String: UIStateSnapshot.Reader] {
        [
            "ui.home": UIStateSnapshot.reader(of: self) { try await $0.stateSnapshot() },
            "ui.home.expression": UIStateSnapshot.reader(of: expressionOwner) { try await $0.stateSnapshot() },
        ]
    }

    public let requests = UIRequests<HomeInput, Void>()
    public let listeningRequests = UIRequests<ListeningInput, Void>(controlOnly: true)

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
        if !value.isLoading { conversation.loadingExpression = false }
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

/// User intent only. No execution identity, device handle or business routing.
public enum ListeningInput: Sendable, Equatable {
    case setEnabled(Bool)
    case toggle
    case press(Bool)
}

public enum HomeInput: Sendable {
    case text(String)
}
