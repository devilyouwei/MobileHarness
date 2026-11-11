import Foundation
import Observation

public enum HomeModelPreparation: Equatable, Sendable {
    case inactive, checking
    case preparing(String)
    case ready, deferred
    case failed(component: String, message: String)
    public var blocksNewActions: Bool { self != .ready }
    public var isLoading: Bool {
        if case .preparing = self { return true }
        return false
    }
    public var showsRetry: Bool {
        if case .failed = self { return true }
        return false
    }
}

public enum VoicePhase: String, CaseIterable, Sendable, Equatable {
    case idle, loading, listening, processing, speaking, failed
}

public enum EyeExpression: String, CaseIterable, Sendable {
    case clear, closed, loading, smile, happy, laugh, thinking, surprised, sad, love, angry, scared, playful
}

/// MainActor presentation values and public rendering ports; module services own business sessions.
@MainActor
@Observable
public final class ConversationState {
    @ObservationIgnored var presentationAdmission: UIPresentationAdmission?
    public var isPresentationAvailable: Bool { presentationAdmission.map { $0.started && !$0.stopped } ?? true }

    public internal(set) var queuedInputs = 0
    public internal(set) var classifyingInputs = 0
    public internal(set) var voicePhase: VoicePhase = .loading
    public internal(set) var liveTranscript = ""
    public internal(set) var transcriptFinalized = false
    public internal(set) var assistantReply = ""
    public internal(set) var assistantReplyOpacity = 1.0
    public internal(set) var expression: EyeExpression?
    /// Display transaction identity only; UI owns the renderer acknowledgment.
    public internal(set) var expressionEmphasized = false
    public internal(set) var expressionTransitionID: String?
    public internal(set) var expressionRendererAvailable = false
    @ObservationIgnored public internal(set) var expressionAnimationCompletion: (@MainActor (String, Bool) -> Void)?
    public internal(set) var playbackSpectrum = [Float](repeating: 0, count: 32)
    public internal(set) var microphoneSpectrum = [Float](repeating: 0, count: 32)
    public internal(set) var bluetoothStatus: BluetoothConnectionStatus = .disconnected
    private var bluetoothRevision: UInt64 = 0
    @discardableResult public func presentBluetoothConnection(_ value: BluetoothConnectionStatus, revision: UInt64)
        -> Bool
    {
        guard presentationAdmission?.acceptsRetained() ?? true, revision > 0, revision >= bluetoothRevision else {
            return false
        }
        guard revision != bluetoothRevision || value == bluetoothStatus else { return false }
        bluetoothRevision = revision
        bluetoothStatus = value
        return true
    }
    public internal(set) var modelPreparation: HomeModelPreparation = .inactive
    public var hasActiveInteraction: Bool { isVoiceActive || isReplyActive }
    public var allowsHomeInteraction: Bool { isReady && (hasActiveInteraction || !modelPreparation.blocksNewActions) }
    public var showsModelPreparation: Bool {
        !hasActiveInteraction && (modelPreparation.isLoading || modelPreparation.showsRetry)
    }
    public var showsModelRetry: Bool { !hasActiveInteraction && modelPreparation.showsRetry }
    public internal(set) var isReady = false
    public internal(set) var voiceStatus = "按住双眼，开启聆听"
    public internal(set) var isVoiceActive = false { didSet { if !isVoiceActive { replyWaitingRequest = nil } } }
    public internal(set) var listeningAnimationID: String?
    /// Normalized content-space origin; latched by the renderer on each new listening generation.
    public internal(set) var listeningLightOrigin: ListeningLightOrigin?
    public internal(set) var decorativeLight: DecorativeLight?
    public internal(set) var graphicsMessage: String?
    public internal(set) var isReplyActive = false {
        didSet { if !isReplyActive { replyWaitingRequest = nil } }
    }
    public internal(set) var replyWaitingRequest: String?
    public internal(set) var listeningControlMessage: String?
    /// Sleep is a presentation gate, independent of processing/speaking pauses in an enabled session.
    public internal(set) var loadingExpression = false
    public var showsLoadingExpression: Bool {
        (loadingExpression && modelPreparation.isLoading && !hasActiveInteraction)
            || (replyWaitingRequest != nil && isVoiceActive && !expressionEmphasized)
    }
    public var displayedExpression: EyeExpression {
        showsLoadingExpression ? .loading : (isVoiceActive ? (expression ?? .clear) : .closed)
    }
    public init() {}
    public func presentPlaybackSpectrum(_ values: [Float]) {
        guard presentationAdmission?.acceptsLive() ?? true else { return }
        playbackSpectrum = values
    }
    public func presentTranscript(_ text: String) {
        guard presentationAdmission?.acceptsLive() ?? true else { return }
        liveTranscript = text
        transcriptFinalized = false
    }
    public func clearReply() {
        guard presentationAdmission?.acceptsLive() ?? true else { return }
        assistantReply = ""
        replyWaitingRequest = nil
    }
    public func presentReplyWaiting(_ enabled: Bool, requestID: String) {
        if enabled {
            guard presentationAdmission?.acceptsLive() ?? true, isVoiceActive else { return }
            replyWaitingRequest = requestID
        } else if replyWaitingRequest == requestID {
            replyWaitingRequest = nil
        }
    }
    public func appendReply(_ text: String) {
        guard presentationAdmission?.acceptsLive() ?? true else { return }
        if !text.isEmpty { replyWaitingRequest = nil }
        assistantReply += text
    }
    public func presentVoiceStatus(_ status: String, clearMicrophone: Bool = false) {
        guard presentationAdmission?.acceptsRetained() ?? true else { return }
        if clearMicrophone { microphoneSpectrum = [Float](repeating: 0, count: 32) }
        voiceStatus = status
    }
    public func resetCaptions() {
        guard presentationAdmission?.acceptsRetained() ?? true else { return }
        replyWaitingRequest = nil
        liveTranscript = ""
        transcriptFinalized = false
        assistantReply = ""
        assistantReplyOpacity = 1
    }
    public func finishUserTranscript() {
        guard presentationAdmission?.acceptsLive() ?? true else { return }
        transcriptFinalized = true
    }

    public var token: UIPresentationToken? { presentationAdmission?.token }
    public func accepts(_ token: UIPresentationToken?) -> Bool { presentationAdmission?.acceptsLive(token) ?? true }
    @discardableResult
    public func present(_ update: ConversationUpdate, token: UIPresentationToken?) -> Bool {
        guard accepts(token) else { return false }
        apply(update)
        return true
    }
    @discardableResult
    public func present(_ update: ConversationUpdate) -> Bool {
        let retained: Bool
        switch update {
        case .isReady, .voiceStatus, .graphicsMessage, .listeningControlMessage, .isVoiceActive(false),
            .isReplyActive(false):
            retained = true
        default: retained = false
        }
        guard
            retained
                ? (presentationAdmission?.acceptsRetained() ?? true) : (presentationAdmission?.acceptsLive() ?? true)
        else { return false }
        apply(update)
        return true
    }
    func apply(_ update: ConversationUpdate) {
        switch update {
        case .inputQueue(let ready, let classifying):
            queuedInputs = max(0, ready)
            classifyingInputs = max(0, classifying)
        case .voicePhase(let value): voicePhase = value
        case .liveTranscript(let value): liveTranscript = value
        case .transcriptFinalized(let value): transcriptFinalized = value
        case .assistantReply(let value): assistantReply = value
        case .playbackSpectrum(let value): playbackSpectrum = value
        case .microphoneSpectrum(let value): microphoneSpectrum = value
        case .isReady(let value): isReady = value
        case .voiceStatus(let value): voiceStatus = value
        case .isVoiceActive(let value): isVoiceActive = value
        case .listeningAnimationID(let value): listeningAnimationID = value
        case .listeningLightOrigin(let value): listeningLightOrigin = value
        case .graphicsMessage(let value): graphicsMessage = value
        case .isReplyActive(let value): isReplyActive = value
        case .listeningControlMessage(let value): listeningControlMessage = value
        }
    }
}

/// Fixed, disjoint role regions; recognition finalization never moves a caption.
public struct ConversationCaptionLayout: Sendable {
    public let captionHeight: CGFloat
    public let captionCenterY: CGFloat
    public let replyHeight: CGFloat
    public let replyCenterY: CGFloat

    public init(viewportHeight: CGFloat, faceDiameter: CGFloat) {
        captionHeight = min(100, viewportHeight * 0.16)
        let top = max(72, viewportHeight * 0.40 - faceDiameter * 0.5 - 31 - captionHeight * 0.5)
        captionCenterY = top + captionHeight * 0.5
        replyHeight = min(120, viewportHeight * 0.20)
        // Reserve the same bottom area even while channels have no visible activity.
        replyCenterY = max(top + captionHeight + 24 + replyHeight * 0.5, viewportHeight - 240)
    }
}

/// Decoration only: does not own listening consent or expression state.
public struct DecorativeLight: Sendable, Equatable {
    public let id: String
    public let origin: ListeningLightOrigin
    public let initialOpacity: Double
    public let intensity: Double
    public init(
        id: String = UUID().uuidString, origin: ListeningLightOrigin, initialOpacity: Double,
        intensity: Double
    ) {
        self.id = id
        self.origin = origin
        self.initialOpacity = initialOpacity
        self.intensity = intensity
    }
}

/// A notice reserves the bottom slot; promoted ASR and the Task goal are independent.
public enum ConversationCaptionVisibility {
    public static func user(isListening: Bool, finalized: Bool, hasNotice: Bool) -> Bool {
        isListening && (finalized || !hasNotice)
    }
    public static func reply(hasNotice: Bool) -> Bool { !hasNotice }
}

public enum ConversationExpressionError: Error, Equatable { case rendererUnavailable, busy }

/// Outcome of a versioned desired-state projection, not an animation receipt.
public enum LoadingExpressionUpdate: Sendable, Equatable { case applied, superseded, rejected }

/// UI-owned transaction and renderer acknowledgment; IDs fence replacement and late callbacks.
@MainActor
public final class ConversationExpressionPresentation: ExpressionPresenting {
    public func stateSnapshot() async throws -> UIStateSnapshot {
        try Task.checkCancellation()
        let expression = expressionSnapshot()
        return UIStateSnapshot(
            path: "ui.home.expression",
            business: [
                "base": .text(expression.base), "effective": .text(expression.effective),
                "overridden": .flag(expression.overridden),
                "transitioning": .flag(expression.transitioning), "loading": .flag(expression.loading),
            ], runtime: ["rendererAvailable": .flag(expression.rendererAvailable)],
            meanings: [
                "business.effective": "Display target; not a rendered pixel receipt",
                "business.base": "Persistent expression restored after the override",
            ],
            stateValues: [
                "business.effective": EyeExpression.allCases.map(\.rawValue),
                "business.base": EyeExpression.allCases.map(\.rawValue),
            ])
    }

    var presentationAdmission: UIPresentationAdmission?
    private let state: ConversationState
    private var loadingRevision: UInt64 = 0
    private var loadingRequest: Bool?
    @discardableResult public func setLoading(_ enabled: Bool, revision: UInt64) -> LoadingExpressionUpdate {
        guard presentationAdmission?.acceptsRetained() ?? true, revision > 0 else { return .rejected }
        if revision < loadingRevision { return .superseded }
        if revision == loadingRevision {
            guard loadingRequest == enabled else { return .rejected }
            return state.loadingExpression == enabled ? .applied : .superseded
        }
        loadingRevision = revision
        loadingRequest = enabled
        guard
            !enabled
                || ((presentationAdmission?.acceptsLive() ?? true) && state.modelPreparation.isLoading
                    && !state.hasActiveInteraction)
        else { return .superseded }
        if enabled, expressionOwner != nil {
            finishExpressionTransition(id: expressionWaitID, completed: false)
            expressionOwner = nil
            state.expressionEmphasized = false
            state.expression = baseExpression
        }
        state.loadingExpression = enabled
        return .applied
    }
    private var baseExpression: EyeExpression?
    private var expressionOwner: String?
    private var expressionWaiter: CheckedContinuation<Void, Error>?
    private var expressionWaitID: String?
    /// Explicit expression facts; effective is a display target, not a pixel receipt.
    public struct ExpressionSnapshot: Encodable, Sendable, Equatable {
        public let base: String
        public let effective: String
        public let overridden: Bool
        public let transitioning: Bool
        public let rendererAvailable: Bool
        public let loading: Bool
    }
    public func expressionSnapshot() -> ExpressionSnapshot {
        ExpressionSnapshot(
            base: baseExpression?.rawValue ?? "clear", effective: state.displayedExpression.rawValue,
            overridden: expressionOwner != nil, transitioning: expressionWaiter != nil,
            rendererAvailable: state.expressionRendererAvailable, loading: state.showsLoadingExpression)
    }
    public init(state: ConversationState) { self.state = state }
    public func setBase(_ expression: EyeExpression?) {
        guard presentationAdmission?.acceptsLive() ?? true else { return }
        baseExpression = expression
        if expressionOwner == nil { state.expression = expression }
    }
    public func perform(_ expression: EyeExpression, owner: String) async throws {
        try presentationAdmission?.requireLive()
        guard !(state.loadingExpression && state.modelPreparation.isLoading && !state.hasActiveInteraction) else {
            throw ConversationExpressionError.busy
        }
        guard state.isVoiceActive || expression == .closed else {
            throw ConversationExpressionError.rendererUnavailable
        }
        guard expressionOwner == nil else { throw ConversationExpressionError.busy }
        expressionOwner = owner
        try await transitionExpression(to: expression, emphasized: true)
    }
    public func restore(owner: String, accepts: Bool) async throws {
        guard expressionOwner == owner else { return }
        if Task.isCancelled || !state.expressionRendererAvailable || !accepts {
            finishExpressionTransition(id: expressionWaitID, completed: false)
            expressionOwner = nil
            state.expressionEmphasized = false
            state.expression = baseExpression
            return
        }
        defer {
            if expressionOwner == owner {
                expressionOwner = nil
                state.expressionEmphasized = false
                state.expression = baseExpression
            }
        }
        try await transitionExpression(to: baseExpression)
    }
    private func transitionExpression(to target: EyeExpression?, emphasized: Bool = false) async throws {
        try Task.checkCancellation()
        guard state.expressionRendererAvailable else { throw ConversationExpressionError.rendererUnavailable }
        guard expressionWaiter == nil else { throw ConversationExpressionError.busy }
        let id = UUID().uuidString
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                expressionWaitID = id
                expressionWaiter = continuation
                state.expressionAnimationCompletion = { [weak self] id, completed in
                    self?.finishExpressionTransition(id: id, completed: completed)
                }
                state.expressionTransitionID = id
                state.expressionEmphasized = emphasized
                state.expression = target
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishExpressionTransition(id: id, completed: false) }
        }
    }

    private func finishExpressionTransition(id: String?, completed: Bool) {
        guard let id, expressionWaitID == id else { return }
        let waiter = expressionWaiter
        expressionWaiter = nil
        expressionWaitID = nil
        state.expressionTransitionID = nil
        state.expressionAnimationCompletion = nil
        if completed { waiter?.resume() } else { waiter?.resume(throwing: CancellationError()) }
    }

    public func resetExpression() {
        state.loadingExpression = false
        state.replyWaitingRequest = nil
        finishExpressionTransition(id: expressionWaitID, completed: false)
        expressionOwner = nil
        baseExpression = nil
        state.expressionEmphasized = false
        state.expression = nil
    }

}

public enum ConversationUpdate {
    case inputQueue(ready: Int, classifying: Int)
    case voicePhase(VoicePhase)
    case liveTranscript(String)
    case transcriptFinalized(Bool)
    case assistantReply(String)
    case playbackSpectrum([Float])
    case microphoneSpectrum([Float])
    case isReady(Bool)
    case voiceStatus(String)
    case isVoiceActive(Bool)
    case listeningAnimationID(String?)
    case listeningLightOrigin(ListeningLightOrigin?)
    case graphicsMessage(String?)
    case isReplyActive(Bool)
    case listeningControlMessage(String?)
}

@MainActor
public protocol ConversationPresenting: UIPresentationAccess {
    var token: UIPresentationToken? { get }
    func accepts(_ token: UIPresentationToken?) -> Bool
    @discardableResult
    func present(_ update: ConversationUpdate, token: UIPresentationToken?) -> Bool
    var voicePhase: VoicePhase { get }
    var liveTranscript: String { get }
    var transcriptFinalized: Bool { get }
    var assistantReply: String { get }
    var assistantReplyOpacity: Double { get }
    var expression: EyeExpression? { get }
    var expressionEmphasized: Bool { get }
    var expressionTransitionID: String? { get }
    var expressionRendererAvailable: Bool { get }
    var playbackSpectrum: [Float] { get }
    var microphoneSpectrum: [Float] { get }
    var isReady: Bool { get }
    var voiceStatus: String { get }
    var isVoiceActive: Bool { get }
    var listeningAnimationID: String? { get }
    var listeningLightOrigin: ListeningLightOrigin? { get }
    var decorativeLight: DecorativeLight? { get }
    var graphicsMessage: String? { get }
    var isReplyActive: Bool { get }
    var listeningControlMessage: String? { get }
    var displayedExpression: EyeExpression { get }
    @discardableResult
    func present(_ update: ConversationUpdate) -> Bool
    func presentPlaybackSpectrum(_ values: [Float])
    func presentTranscript(_ text: String)
    func clearReply()
    func presentReplyWaiting(_ enabled: Bool, requestID: String)
    func appendReply(_ text: String)
    func presentVoiceStatus(_ status: String, clearMicrophone: Bool)
    func resetCaptions()
    func finishUserTranscript()
}

extension ConversationState: ConversationPresenting {}

extension ConversationPresenting {
    public func presentVoiceStatus(_ status: String) { presentVoiceStatus(status, clearMicrophone: false) }
}

@MainActor
public protocol ExpressionPresenting: AnyObject, Sendable {
    @discardableResult func setLoading(_ enabled: Bool, revision: UInt64) -> LoadingExpressionUpdate
    func setBase(_ expression: EyeExpression?)
    func perform(_ expression: EyeExpression, owner: String) async throws
    func restore(owner: String, accepts: Bool) async throws
    func resetExpression()
}

extension ConversationState: BluetoothConnectionPresenting {}
