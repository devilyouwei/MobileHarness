import Foundation
import FunctionContracts
import UI

/// Root-owned latest-state decorations. Expiry is independent of page lifetime.
@MainActor
public final class HomeEffectsWorkflow {
    public enum Error: Swift.Error { case busy, unavailable, invalidArguments }
    private let activity: ActionActivityState
    private weak var conversation: ConversationState?
    private var replyExpiry: Task<Void, Never>?
    private var replyFadeID: UUID?
    private var noticeExpiry: Task<Void, Never>?
    private var lightExpiry: Task<Void, Never>?
    private var noticeOwner: Owner?
    private var lightOwner: Owner?
    private struct Owner: Equatable {
        let source: String
        let session: UUID
        init(_ input: any FunctionInput) {
            source = input.context.source
            session = input.context.sessionID
        }
    }
    public init(activity: ActionActivityState) { self.activity = activity }
    public func bind(_ state: ConversationState) { conversation = state }
    deinit {
        replyExpiry?.cancel()
        noticeExpiry?.cancel()
        lightExpiry?.cancel()
    }
    public func replyDidBegin() {
        replyExpiry?.cancel()
        replyExpiry = nil
        replyFadeID = nil
        conversation?.assistantReplyOpacity = 1
    }
    public func replyDidFinish() {
        guard replyExpiry == nil, let conversation, conversation.isVoiceActive, !conversation.assistantReply.isEmpty
        else { return }
        let id = UUID()
        let text = conversation.assistantReply
        replyFadeID = id
        conversation.assistantReplyOpacity = 0
        replyExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, self.replyFadeID == id else { return }
            if self.conversation?.assistantReply == text { self.conversation?.assistantReply = "" }
            self.conversation?.assistantReplyOpacity = 1
            self.replyExpiry = nil
            self.replyFadeID = nil
        }
    }
    public func stop() {
        replyDidBegin()
        noticeExpiry?.cancel()
        noticeExpiry = nil
        lightExpiry?.cancel()
        lightExpiry = nil
        activity.notice = nil
        conversation?.decorativeLight = nil
        noticeOwner = nil
        lightOwner = nil
    }
    public func showNotice(_ notice: HomeNotice, durationMS: Int = 8000, invocation: any FunctionInput) async throws {
        try Task.checkCancellation()
        guard (500...30000).contains(durationMS), !notice.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            notice.text.utf8.count <= 1024
        else { throw Error.invalidArguments }
        guard activity.errorToast == nil else { throw Error.busy }
        noticeExpiry?.cancel()
        activity.notice = notice
        noticeOwner = Owner(invocation)
        noticeExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(durationMS)) } catch { return }
            guard let self, self.activity.notice?.id == notice.id else { return }
            self.activity.notice = nil
            self.noticeOwner = nil
            self.noticeExpiry = nil
        }
    }
    public func dismissNotice(invocation: any FunctionInput) async throws {
        try Task.checkCancellation()
        guard noticeOwner == nil || noticeOwner == Owner(invocation) else { throw Error.busy }
        noticeExpiry?.cancel()
        noticeExpiry = nil
        noticeOwner = nil
        activity.notice = nil
    }
    public func updateLight(_ light: DecorativeLight?, durationMS: Int = 3000, invocation: any FunctionInput)
        async throws
    {
        try Task.checkCancellation()
        guard let conversation else { throw Error.unavailable }
        guard (500...30000).contains(durationMS) else { throw Error.invalidArguments }
        guard let light else {
            guard lightOwner == nil || lightOwner == Owner(invocation) else { throw Error.busy }
            lightExpiry?.cancel()
            lightExpiry = nil
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
        lightOwner = Owner(invocation)
        lightExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(durationMS)) } catch { return }
            guard let self, self.conversation?.decorativeLight?.id == light.id else { return }
            self.conversation?.decorativeLight = nil
            self.lightOwner = nil
            self.lightExpiry = nil
        }
    }
}
