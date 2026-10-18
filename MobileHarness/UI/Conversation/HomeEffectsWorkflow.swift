import Foundation

/// Root-owned latest-state decorations. Expiry is independent of page lifetime.
@MainActor
public final class HomeEffectsWorkflow: HomeEffectsPresenting {
    public enum Error: Swift.Error { case busy, unavailable, invalidArguments }
    var presentationAdmission: UIPresentationAdmission?
    private let activity: ActionActivityState
    private weak var conversation: ConversationState?
    private var replyExpiry: Task<Void, Never>?
    private var replyFadeID: String?
    private var noticeExpiry: Task<Void, Never>?
    private var lightExpiry: Task<Void, Never>?
    private var noticeOwner: PresentationOwner?
    private var lightOwner: PresentationOwner?
    public init(activity: ActionActivityState) { self.activity = activity }
    public func bind(_ state: ConversationState) { conversation = state }
    deinit {
        replyExpiry?.cancel()
        noticeExpiry?.cancel()
        lightExpiry?.cancel()
    }
    public func replyDidBegin() {
        replyExpiry?.cancel()
        replyFadeID = nil
        conversation?.assistantReplyOpacity = 1
    }
    public func replyDidFinish() {
        guard replyFadeID == nil, presentationAdmission?.acceptsLive() ?? true, let conversation,
            conversation.isVoiceActive, !conversation.assistantReply.isEmpty
        else { return }
        let id = UUID().uuidString
        let text = conversation.assistantReply
        replyFadeID = id
        conversation.assistantReplyOpacity = 0
        let previousReply = replyExpiry
        previousReply?.cancel()
        replyExpiry = Task { [weak self] in
            await previousReply?.value
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, self.replyFadeID == id else { return }
            if self.conversation?.assistantReply == text { self.conversation?.assistantReply = "" }
            self.conversation?.assistantReplyOpacity = 1
            self.replyFadeID = nil
        }
    }
    public func stop() {
        replyDidBegin()
        noticeExpiry?.cancel()
        lightExpiry?.cancel()
        activity.notice = nil
        conversation?.decorativeLight = nil
        noticeOwner = nil
        lightOwner = nil
    }
    public func stopAndWait() async {
        let tasks = [replyExpiry, noticeExpiry, lightExpiry]
        stop()
        for task in tasks { await task?.value }
        replyExpiry = nil
        noticeExpiry = nil
        lightExpiry = nil
        conversation = nil
    }
    public func showNotice(_ notice: HomeNotice, durationMS: Int = 8000, owner: PresentationOwner) async throws {
        try Task.checkCancellation()
        try presentationAdmission?.requireLive()
        guard (500...30000).contains(durationMS), !notice.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            notice.text.utf8.count <= 1024
        else { throw Error.invalidArguments }
        guard activity.errorToast == nil else { throw Error.busy }
        noticeExpiry?.cancel()
        activity.notice = notice
        noticeOwner = owner
        let previousNotice = noticeExpiry
        previousNotice?.cancel()
        noticeExpiry = Task { [weak self] in
            await previousNotice?.value
            do { try await Task.sleep(for: .milliseconds(durationMS)) } catch { return }
            guard let self, self.activity.notice?.id == notice.id else { return }
            self.activity.notice = nil
            self.noticeOwner = nil
        }
    }
    public func dismissNotice(owner: PresentationOwner) async throws {
        try Task.checkCancellation()
        guard noticeOwner == nil || noticeOwner == owner else { throw Error.busy }
        noticeExpiry?.cancel()
        noticeOwner = nil
        activity.notice = nil
    }
    public func updateLight(_ light: DecorativeLight?, durationMS: Int = 3000, owner: PresentationOwner)
        async throws
    {
        try Task.checkCancellation()
        if light != nil { try presentationAdmission?.requireLive() }
        guard let conversation else { throw Error.unavailable }
        guard (500...30000).contains(durationMS) else { throw Error.invalidArguments }
        guard let light else {
            guard lightOwner == nil || lightOwner == owner else { throw Error.busy }
            lightExpiry?.cancel()
            lightOwner = nil
            conversation.decorativeLight = nil
            return
        }
        guard conversation.expressionRendererAvailable else { throw Error.unavailable }
        guard [light.initialOpacity, light.intensity].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw Error.invalidArguments
        }
        lightExpiry?.cancel()
        conversation.decorativeLight = light
        lightOwner = owner
        let previousLight = lightExpiry
        previousLight?.cancel()
        lightExpiry = Task { [weak self] in
            await previousLight?.value
            do { try await Task.sleep(for: .milliseconds(durationMS)) } catch { return }
            guard let self, self.conversation?.decorativeLight?.id == light.id else { return }
            self.conversation?.decorativeLight = nil
            self.lightOwner = nil
        }
    }
}

/// Opaque UI ownership; presentation never interprets business transport types.
public struct PresentationOwner: Sendable, Equatable {
    public let source: String
    public let session: String
    public init(source: String, session: String) {
        self.source = source
        self.session = session
    }
}

@MainActor
public protocol HomeEffectsPresenting: AnyObject, Sendable {
    func replyDidBegin()
    func replyDidFinish()
    func stop()
    func showNotice(_ notice: HomeNotice, durationMS: Int, owner: PresentationOwner) async throws
    func dismissNotice(owner: PresentationOwner) async throws
    func updateLight(_ light: DecorativeLight?, durationMS: Int, owner: PresentationOwner) async throws
}
