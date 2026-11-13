import Foundation
import Observation

@MainActor
@Observable
public final class HomeNoticeState {
    @ObservationIgnored var presentationAdmission: UIPresentationAdmission?

    public init() {}

    public internal(set) var notice: HomeNotice?
    public var visibleNotice: HomeNotice? {
        if let errorToast {
            return HomeNotice(
                id: errorToast.id,
                text: errorToast.userMessage ?? errorToast.message.replacingOccurrences(of: "agent.error: ", with: ""),
                tone: .error)
        }
        return notice?.placement == .caption ? notice : nil
    }
    public var transientToast: HomeNotice? { notice?.placement == .toast ? notice : nil }
    public private(set) var errorToast: ExecutionIssue?
    @ObservationIgnored var toastDuration = Duration.seconds(8)
    @ObservationIgnored private var toastExpiry: Task<Void, Never>?
    private var toastKeys: [String] = []
    public func dismissErrorToast(id: String) { if errorToast?.id == id { errorToast = nil } }
    public func offerToast(_ issue: ExecutionIssue, now: Date = Date()) {
        // Stale and repeated evidence remains available in the log.
        guard presentationAdmission?.active ?? true, issue.context?.callID == nil,
            (-5...15).contains(now.timeIntervalSince(issue.time))
        else { return }
        let key = "\(issue.source)|\(issue.inputID ?? issue.id)|\(issue.message)"
        guard !toastKeys.contains(key) else { return }
        toastKeys.append(key)
        toastKeys = Array(toastKeys.suffix(100))
        errorToast = issue
        let previous = toastExpiry
        previous?.cancel()
        toastExpiry = Task { [weak self] in
            await previous?.value
            do { try await Task.sleep(for: self?.toastDuration ?? .seconds(8)) } catch { return }
            self?.dismissErrorToast(id: issue.id)
        }
    }
    deinit { toastExpiry?.cancel() }
    func stopPresentation() async {
        toastExpiry?.cancel()
        await toastExpiry?.value
        toastExpiry = nil
        errorToast = nil
        notice = nil
    }
}

/// A display notice is never an ExecutionIssue or a task goal.
public struct HomeNotice: Sendable, Equatable {
    public enum Tone: String, Sendable { case info, warning, error }
    public enum Placement: Sendable { case caption, toast }
    public let placement: Placement
    public let id: String
    public let text: String
    public let tone: Tone
    public init(id: String = UUID().uuidString, text: String, tone: Tone, placement: Placement = .caption) {
        self.placement = placement
        self.id = id
        self.text = text
        self.tone = tone
    }
}
