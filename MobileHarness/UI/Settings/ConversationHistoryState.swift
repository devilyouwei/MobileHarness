import Foundation
import Observation

@MainActor
@Observable
public final class ConversationHistoryState {
    @ObservationIgnored var presentationAdmission: UIPresentationAdmission?
    public var isPresentationAvailable: Bool { presentationAdmission.map { $0.started && !$0.stopped } ?? true }

    public let title: String
    public internal(set) var selectedConversation: HistoryConversation?
    public internal(set) var archive: HistorySnapshot?
    public internal(set) var status: String?
    public internal(set) var isBusy = false
    public internal(set) var isRefreshing = false
    public internal(set) var hasMoreArchives = false
    public internal(set) var archivePaging = HistoryPageLoading<String>()
    public func present(_ snapshot: HistorySnapshot, status: String?) {
        guard presentationAdmission?.acceptsRetained() ?? true else { return }
        archive = snapshot
        self.status = status
    }
    public init(title: String = "Assistant 聊天记录") {
        self.title = title
    }

    @discardableResult
    public func present(_ update: HistoryUpdate) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        apply(update)
        return true
    }
    func apply(_ update: HistoryUpdate) {
        switch update {
        case .selectedConversation(let value): selectedConversation = value
        case .archive(let value): archive = value
        case .status(let value): status = value
        case .isBusy(let value): isBusy = value
        case .isRefreshing(let value): isRefreshing = value
        case .hasMoreArchives(let value): hasMoreArchives = value
        case .archivePaging(let value): archivePaging = value
        }
    }
}

/// Scoped to a page's identity: returning from a child does not request its first page again.
public struct HistoryInitialLoad: Sendable {
    private enum Phase: Sendable { case idle, loading, loaded }
    private var phase = Phase.idle
    public init() {}
    public mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .loading
        return true
    }
    public mutating func finish(succeeded: Bool) {
        if succeeded {
            phase = .loaded
        } else if phase == .loading {
            phase = .idle
        }
    }
}

/// One attempt per cursor unless the user explicitly retries; tickets fence late completions.
public struct HistoryPageLoading<Cursor: Hashable & Sendable>: Sendable {
    public private(set) var error: String?
    public private(set) var completionID: UUID?
    private var attemptedCursor: Cursor?
    private var active: UUID?
    public var isLoading: Bool { active != nil }
    public init() {}
    public mutating func begin(after cursor: Cursor, retry: Bool = false) -> UUID? {
        guard active == nil, retry || attemptedCursor != cursor else { return nil }
        let ticket = UUID()
        attemptedCursor = cursor
        active = ticket
        error = nil
        return ticket
    }
    public func accepts(_ ticket: UUID) -> Bool { active == ticket }
    public mutating func finish(_ ticket: UUID, error: String? = nil) {
        guard accepts(ticket) else { return }
        active = nil
        self.error = error.map { String($0.prefix(2048)) }
        completionID = UUID()
    }
    public mutating func cancel(_ ticket: UUID) {
        guard accepts(ticket) else { return }
        active = nil
        attemptedCursor = nil
        error = nil
        completionID = UUID()
    }
}

/// One request destination per history page; repeated taps cannot append destinations.
public struct HistoryRequestNavigation {
    public private(set) var turn: HistoryTurn?
    public var isPresented = false
    public init() {}
    public mutating func open(_ turn: HistoryTurn) {
        guard !isPresented else { return }
        self.turn = turn
        isPresented = true
    }
}

/// Page-owned read: one active read and one latest candidate, never a chain of waiting tasks.
@MainActor
@Observable
final class HistoryMessageLoader {
    private struct Request {
        let id: UUID
        let read: @MainActor () async throws -> HistoryTurn
        let show: @MainActor (HistoryTurn) -> Void
    }
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<HistoryTurn, Error>?
    @ObservationIgnored private var pending: Request?
    private var requestID: UUID?

    func open(
        read: @escaping @MainActor () async throws -> HistoryTurn, show: @escaping @MainActor (HistoryTurn) -> Void
    ) {
        guard !isLoading else { return }
        let id = UUID()
        requestID = id
        isLoading = true
        error = nil
        pending = Request(id: id, read: read, show: show)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let request = self?.takePending() {
                let task = Task {
                    try Task.checkCancellation()
                    return try await request.read()
                }
                self?.readTask = task
                let result = await task.result
                self?.readTask = nil
                self?.complete(request, result: result)
            }
            self?.worker = nil
        }
    }
    private func takePending() -> Request? {
        defer { pending = nil }
        return pending
    }
    private func complete(_ request: Request, result: Result<HistoryTurn, Error>) {
        guard requestID == request.id else { return }
        requestID = nil
        isLoading = false
        switch result {
        case .success(let turn): request.show(turn)
        case .failure(let failure):
            if !(failure is CancellationError) { error = "读取失败：\(failure)" }
        }
    }
    func cancel() {
        requestID = nil
        pending = nil
        isLoading = false
        error = nil
        readTask?.cancel()
    }
    func stopAndWait() async {
        cancel()
        await worker?.value
    }
    deinit { readTask?.cancel() }
}

@MainActor
public protocol ConversationHistoryControlling: AnyObject {
    func load() async
    func loadConversation(_ id: String) async throws -> HistoryConversation
    func loadConversation(_ id: String, after: UInt64, taskID: String?) async throws -> HistoryConversation
    func loadMessage(_ turn: HistoryTurn) async throws -> HistoryTurn
    func loadMoreArchives(retry: Bool) async
    func startNew()
    func summarize(_ id: String)
    func delete(_ id: String)
    func cancel()
    func preview(_ turn: HistoryTurn) -> String
    func imageData(_ id: String, for turnID: String) async throws -> Data?
}

public struct HistoryMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    public let role: Role
    public let content: String
    public let toolCalls: [HistoryNativeToolCall]?
    public let toolCallID: String?
    public let imageReferences: [HistoryImageReference]?
    public init(role: Role, content: String, imageReferences: [HistoryImageReference] = []) {
        self.role = role
        self.content = content
        toolCalls = nil
        toolCallID = nil
        self.imageReferences = imageReferences.isEmpty ? nil : imageReferences
    }
}

public struct HistoryImageReference: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let mimeType: String
    public let byteCount: Int
    public init(id: String, mimeType: String, byteCount: Int) {
        self.id = id
        self.mimeType = mimeType
        self.byteCount = byteCount
    }
    public var isValid: Bool {
        ["image/jpeg", "image/png"].contains(mimeType) && byteCount > 0 && byteCount <= 4 * 1024 * 1024
    }
}

public struct HistoryNativeToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
}

public struct HistoryDecisionMetadata: Codable, Sendable {
    public var runID: String? = nil
    public var taskGoal: String? = nil
    public var execution: String? = nil
    public let taskID: String?
    public let mode: String
    public let skills: [String: Int]
    public let catalogJSON: String
    public var summary: String {
        (execution == nil ? "默认对话" : (execution == "background" ? "后台任务" : "前台任务") + " · " + (taskGoal ?? ""))
            + " · Skills: "
            + skills.keys.sorted().map { "\($0)@\(skills[$0] ?? 0)" }.joined(separator: ", ")
    }
}

public struct HistoryFailureDiagnostic: Codable, Sendable, Equatable {
    public let category: String
    public let code: String
    public let stage: String
    public let message: String
    public let details: [String: String]
    public let causes: [HistoryFailureDiagnostic]
}

public struct HistoryRuntimeEffect: Codable, Sendable, Identifiable {
    public let id: String
    public let resultsJSON: String
}
public struct HistoryModelRequest: Codable, Sendable, Identifiable {
    public var messageID: String? = nil
    public var isObservation: Bool? = nil
    public var historyOrder: UInt64 = 0
    public let id: String
    public let date: Date
    public let input: String
    public let requestJSON: String
    public var historyTaskID: String? = nil
    public var decisionMetadata: HistoryDecisionMetadata? = nil
    public let modelRequestStartedAt: Date?
    public let firstTokenLatency: Double?
    public let firstTokenAt: Date?
    public let response: String
    public let toolCalls: [HistoryToolCall]
    public let tokenUsage: HistoryTokenUsage?
    public let state: HistoryTurn.State
    public let finishReason: String?
    public let error: String?
    public var failureDiagnostic: HistoryFailureDiagnostic? = nil
}

public struct HistoryTokenUsage: Codable, Sendable, Equatable {
    public let input: Int
    public let generated: Int
    public let total: Int
    public let cachedInput: Int?
    public let cacheWriteInput: Int?
    public init(
        input: Int, generated: Int, total: Int, cachedInput: Int? = nil, cacheWriteInput: Int? = nil
    ) {
        self.input = input
        self.generated = generated
        self.total = total
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
    }
}

public struct HistoryToolCall: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case received, completed, failed, cancelled }
    public let id: String
    public let providerID: String
    public let name: String
    public let argumentsJSON: String
    public var state: State = .received
    public let output: String?
    public let error: String?
    public var failureDiagnostic: HistoryFailureDiagnostic? = nil
    public init(id: String, providerID: String, name: String, argumentsJSON: String) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.argumentsJSON = argumentsJSON
        output = nil
        error = nil
    }
}

public struct HistoryTurn: Codable, Sendable, Identifiable {
    public var generationRounds: [HistoryRuntimeEffect]? = nil
    public var messageID: String? = nil
    public var historyOrder: UInt64? = nil
    public enum State: String, Codable, Sendable { case generating, completed, failed, cancelled, interrupted }
    public let id: String
    public let date: Date
    public let user: String
    public let request: [HistoryMessage]
    public let model: String
    public let maximumOutputTokens: Int?
    public let temperature: Double
    public let modelRequests: [HistoryModelRequest]?
    public let firstTokenAt: Date?
    public let requestJSON: String?
    public let ownerInputID: String?
    public let isReACT: Bool?
    public let toolDefinitions: [String]?
    public let toolCalls: [HistoryToolCall]?
    public let tokenUsage: HistoryTokenUsage?
    public var response: String = ""
    public var state: State = .generating
    public let finishReason: String?
    public let error: String?
    public var failureDiagnostic: HistoryFailureDiagnostic? = nil
    public let executionError: String?
    public var historyTaskID: String? = nil
    public var decisionMetadata: HistoryDecisionMetadata? = nil
    public var modelRequestStartedAt: Date?
    public var firstTokenLatency: Double?
    public var raw: String { response }
}

public struct HistoryConversation: Codable, Sendable, Identifiable {
    public var nextPosition: UInt64? = nil
    public let id: String
    public let createdAt: Date
    public let archivedAt: Date?
    public let summaryTitle: String?
    public let titleError: String?
    public var turnCount: Int?
    public var latestUser: String?
    public var turns: [HistoryTurn] = []
    public var taskCompressions: [HistoryTaskCompression] = []
    public init() {
        id = UUID().uuidString
        createdAt = Date()
        archivedAt = nil
        summaryTitle = nil
        titleError = nil
    }
    /// Append a SQL preview/source page without dropping the summaries needed to render Task cards.
    public mutating func appendPage(_ page: HistoryConversation) throws {
        guard page.id == id else { throw HistoryDetailError.unavailable }
        turns.append(contentsOf: page.turns)
        for compression in page.taskCompressions {
            if let index = taskCompressions.firstIndex(where: { $0.taskID == compression.taskID }) {
                taskCompressions[index] = compression
            } else {
                taskCompressions.append(compression)
            }
        }
        nextPosition = page.nextPosition
        turnCount = page.turnCount ?? turnCount
        latestUser = page.latestUser ?? latestUser
    }
}

public struct HistorySnapshot: Codable, Sendable {
    public let version: Int
    public var current: HistoryConversation
    public var past: [HistoryConversation]
    public init() {
        version = 4
        current = HistoryConversation()
        past = []
    }
}

public struct HistorySourceReference: Codable, Sendable, Hashable {
    public let inputID: String
    public let requestID: String
}

public struct HistoryTaskCompression: Codable, Sendable, Identifiable {
    public var id: String { taskID }
    public let taskID: String
    public let goal: String
    public let status: HistoryTurn.State
    public let reportedSummary: String?
    public let failure: String?
    public let completedAt: Date
    public let sources: [HistorySourceReference]
    public var text: String {
        [reportedSummary, failure.map { "失败：" + $0 }].compactMap { $0 }.joined(separator: "\n")
    }
}

public enum HistoryTimelineItem: Identifiable, Sendable {
    case request(HistoryTurn)
    case task(HistoryTaskCompression, sources: [HistoryTurn])
    public var id: String {
        switch self {
        case .request(let turn): turn.id
        case .task(let compression, _): compression.taskID
        }
    }
}

public enum HistoryDetailError: Error { case unavailable }

public enum HistoryUpdate {
    case selectedConversation(HistoryConversation?)
    case archive(HistorySnapshot?)
    case status(String?)
    case isBusy(Bool)
    case isRefreshing(Bool)
    case hasMoreArchives(Bool)
    case archivePaging(HistoryPageLoading<String>)
}

@MainActor
public protocol HistoryPresenting: UIPresentationAccess {
    var selectedConversation: HistoryConversation? { get }
    var archive: HistorySnapshot? { get }
    var status: String? { get }
    var isBusy: Bool { get }
    var isRefreshing: Bool { get }
    var hasMoreArchives: Bool { get }
    var archivePaging: HistoryPageLoading<String> { get }
    var title: String { get }
    @discardableResult
    func present(_ update: HistoryUpdate) -> Bool
    func present(_ snapshot: HistorySnapshot, status: String?)
}

extension ConversationHistoryState: HistoryPresenting {}

extension HistoryPresenting {
    public func beginArchivePage(after id: String, retry: Bool) -> UUID? {
        var paging = archivePaging
        guard let ticket = paging.begin(after: id, retry: retry), present(.archivePaging(paging)) else { return nil }
        return ticket
    }
    public func cancelArchivePage(_ ticket: UUID) {
        var paging = archivePaging
        paging.cancel(ticket)
        present(.archivePaging(paging))
    }
    public func finishArchivePage(_ ticket: UUID, error: String? = nil) {
        var paging = archivePaging
        paging.finish(ticket, error: error)
        present(.archivePaging(paging))
    }
    public func appendArchives(_ page: [HistoryConversation]) {
        guard var value = archive else { return }
        value.past.append(contentsOf: page)
        present(.archive(value))
    }
}

@MainActor
public final class UIHistoryContainer {
    public func stateSnapshot() async throws -> UIStateSnapshot {
        try Task.checkCancellation()
        return UIStateSnapshot(
            path: "ui.history",
            business: [
                "busy": .flag(state.isBusy), "refreshing": .flag(state.isRefreshing),
                "hasMore": .flag(state.hasMoreArchives),
            ], runtime: ["available": .flag(state.isPresentationAvailable)])
    }

    public let requests = UIRequests<HistoryInput, HistoryReply>()

    public let state: ConversationHistoryState
    public var presentation: any HistoryPresenting { state }
    init(title: String, admission: UIPresentationAdmission) {
        state = ConversationHistoryState(title: title)
        state.presentationAdmission = admission
    }
}

public enum HistoryInput: Sendable {
    case refresh, startNew
    case summarize(String)
    case delete(String)
    case conversation(String)
    case message(String)
    case page(String, UInt64, String?)
    case archives(Int64)
    case photo(String, String)
}
public enum HistoryReply: Sendable {
    case completed
    case conversation(HistoryConversation)
    case archives([HistoryConversation])
    case photo(Data?)
}
