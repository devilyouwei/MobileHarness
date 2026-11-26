import AgentCore
import Foundation
import ModelKit
import StorageTasks
import Synchronization

/// Owns the Assistant's listening gate and its quiet decision episode.
public final class ListeningCoordinator: ListeningControlling, Sendable {
    public static let maximumConsecutiveFailures = 3

    private struct State {
        var isListening = true
        var episodeID: String?
        var wakeCondition: String?
        var judgment: Task<Void, Never>?
        var judgmentID: UUID?
        var failures = 0
        var cancelReply: (@Sendable () async throws -> Void)?
        var enableListening: (@Sendable () async throws -> Void)?
        var release: (@Sendable (AgentInput) async throws -> Void)?

        mutating func retireJudgment() -> Task<Void, Never>? {
            let task = judgment
            judgment = nil
            judgmentID = nil
            return task
        }
    }
    private let state = Mutex(State())
    private let judge: QuietExitJudge?
    private let dialogs: (any ListeningDialogRepository)?
    private let sessionID: String
    private let report: @Sendable (String) -> Void

    public init(
        judge: QuietExitJudge?, dialogs: (any ListeningDialogRepository)?, sessionID: String,
        report: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.judge = judge
        self.dialogs = dialogs
        self.sessionID = sessionID
        self.report = report
    }

    public func bind(
        cancelReply: @escaping @Sendable () async throws -> Void,
        enableListening: @escaping @Sendable () async throws -> Void,
        release: @escaping @Sendable (AgentInput) async throws -> Void = { _ in }
    ) {
        state.withLock {
            $0.cancelReply = cancelReply
            $0.enableListening = enableListening
            $0.release = release
        }
    }

    public var isListening: Bool { state.withLock { $0.isListening } }

    public func apply(_ listening: Bool, source: AgentStateSource, wakeCondition: String?) async throws {
        let (previous, cancelReply) = state.withLock { ($0.isListening, $0.cancelReply) }
        // Only a host write can join a running generation. Model writes occur within it.
        if source == .host, !listening, previous { try await cancelReply?() }
        let old = state.withLock { value -> Task<Void, Never>? in
            if !listening && !value.isListening && wakeCondition == nil { return nil }
            let pending = value.retireJudgment()
            value.wakeCondition = listening ? nil : wakeCondition
            value.episodeID = listening ? nil : UUID().uuidString
            value.failures = 0
            value.isListening = listening
            return pending
        }
        old?.cancel()
    }

    // MARK: - quiet

    /// In `quiet` a recognized utterance is judged here instead of entering the conversation.
    public func receiveQuiet(_ text: String, _ input: AgentInput) {
        let older = state.withLock { value -> Task<Void, Never>? in
            guard let episode = value.episodeID else { return nil }
            let condition = value.wakeCondition
            let id = UUID()
            let old = value.judgment
            value.judgmentID = id
            value.judgment = Task { [self] in
                await judgeUtterance(text, input, episode: episode, id: id, wakeCondition: condition)
            }
            return old
        }
        older?.cancel()
    }

    private func isCurrent(_ episode: String, _ id: UUID) -> Bool {
        state.withLock { !$0.isListening && $0.episodeID == episode && $0.judgmentID == id } && !Task.isCancelled
    }

    private func judgeUtterance(_ text: String, _ input: AgentInput, episode: String, id: UUID, wakeCondition: String?)
        async
    {
        guard isCurrent(episode, id) else { return }
        guard let judge else {
            await record(text, episode: episode, error: "No exit judge is configured")
            return
        }
        do {
            let result = try await judge.judge(
                text, wakeCondition: wakeCondition,
                context: .init(requestID: input.id + ".awake", scopeID: input.sessionID))
            guard isCurrent(episode, id) else { return }
            state.withLock { $0.failures = 0 }
            await record(text, episode: episode, judgement: result)
            if result.decision == .exit { await leaveQuiet(text, input, episode: episode, id: id) }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(episode, id) else { return }
            let failures = state.withLock { value -> Int in
                value.failures += 1
                return value.failures
            }
            await record(text, episode: episode, error: String(describing: error))
            if failures == Self.maximumConsecutiveFailures {
                report("Listening is waiting in quiet mode: the exit judge failed \(failures) times in a row.")
            }
        }
    }

    private func leaveQuiet(_ text: String, _ input: AgentInput, episode: String, id: UUID) async {
        typealias Enable = @Sendable () async throws -> Void
        typealias Release = @Sendable (AgentInput) async throws -> Void
        let transition = state.withLock { value -> (Enable?, Release?)? in
            guard value.episodeID == episode, value.judgmentID == id, !Task.isCancelled else { return nil }
            value.judgment = nil
            value.judgmentID = nil
            return (value.enableListening, value.release)
        }
        guard let (enable, release) = transition else { return }
        do {
            guard let enable, let release else {
                throw CapabilityError.unavailable("Listening state cannot be written")
            }
            try await enable()
            try await release(input)
        } catch {
            await record(text, episode: episode, error: "Leaving quiet failed: \(error)")
            report("Could not leave quiet mode: \(error)")
        }
    }

    public func cancelJudgment() {
        let pending = state.withLock { $0.retireJudgment() }
        pending?.cancel()
    }

    private func record(
        _ text: String, episode: String, judgement: QuietJudgement? = nil, error: String? = nil
    ) async {
        guard let dialogs else { return }
        let record = ListeningDialogRecord(
            sessionID: sessionID, episodeID: episode,
            text: String(decoding: Array(text.utf8.prefix(ListeningDialogRecord.maximumTextBytes)), as: UTF8.self),
            decision: judgement.map { $0.decision == .exit ? .exit : .stay } ?? .error,
            modelTier: judgement?.tier, modelID: judgement?.modelID, latencyMS: judgement?.latencyMS ?? 0,
            error: error)
        do { try await dialogs.appendListeningDialog(record) } catch {
            report("Could not save the quiet-mode record: \(error)")
        }
    }
}
