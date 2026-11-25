import AgentCore
import Foundation
import ModelKit
import StorageTasks
import Synchronization

/// Owns the live effect of the `listening` variable: the published mode, the `quiet` exit judgment and its record.
/// It is the handler behind the `listening` trigger and the only writer that ends `quiet`. Other Agents learn the
/// mode only from the Signal it publishes; it holds no reference to them.
///
/// At most one judgment runs: a newer utterance cancels the older one and only the newest result counts. Failures
/// never leave `quiet`; the user hears nothing until the judge answers `exit` or the mode is changed another way.
public final class ListeningCoordinator: ListeningModeControlling, Sendable {
    public static let maximumConsecutiveFailures = 3

    private struct State {
        var mode = ListeningMode.default
        /// The mode `quiet` returns to.
        var resume = ListeningMode.default
        /// `full` was given up because the route cannot cancel echo; it returns when a capture supports it.
        var fellBack = false
        var episodeID: String?
        var wakeCondition: String?
        /// Whether the current capture cancels echo; `nil` until a capture has reported.
        var fullDuplexSupported: Bool?
        var judgment: Task<Void, Never>?
        var judgmentID: UUID?
        var failures = 0
        var cancelReply: (@Sendable () async throws -> Void)?
        var writeMode: (@Sendable (ListeningMode) async throws -> Void)?
        var publishMode: (@Sendable (ListeningMode) async throws -> Void)?
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

    /// Operations that exist only after the Assistant is built: stop the reply being spoken, write the `listening`
    /// variable as the host, publish the mode Signal, and admit an utterance that ended `quiet` as ordinary speech.
    public func bind(
        cancelReply: @escaping @Sendable () async throws -> Void,
        writeMode: @escaping @Sendable (ListeningMode) async throws -> Void,
        publishMode: @escaping @Sendable (ListeningMode) async throws -> Void = { _ in },
        release: @escaping @Sendable (AgentInput) async throws -> Void = { _ in }
    ) {
        state.withLock {
            $0.cancelReply = cancelReply
            $0.writeMode = writeMode
            $0.publishMode = publishMode
            $0.release = release
        }
    }

    public var mode: ListeningMode { state.withLock { $0.mode } }

    // MARK: - Trigger

    /// `full` is rejected when the current capture is known not to cancel echo; with no capture yet it is accepted
    /// and re-checked when one reports. The perception Agent adopts the published mode.
    public func apply(_ mode: ListeningMode, source: AgentStateSource, wakeCondition: String?) async throws {
        let (previous, cancelReply, publishMode, duplex) = state.withLock {
            ($0.mode, $0.cancelReply, $0.publishMode, $0.fullDuplexSupported)
        }
        if mode == .full, duplex == false {
            throw AgentStateError.rejected(
                "listening", reason: "Full duplex needs echo cancellation, which the current microphone route lacks.")
        }
        // A model write runs inside the generation being settled. Only host writes can join that generation.
        if source == .host, mode == .quiet, previous != .quiet { try await cancelReply?() }
        let old = state.withLock { value -> Task<Void, Never>? in
            value.fellBack = false
            if mode == .quiet, previous == .quiet, wakeCondition == nil { return nil }
            let pending = value.retireJudgment()
            value.wakeCondition = mode == .quiet ? wakeCondition : nil
            if mode == .quiet {
                if previous != .quiet {
                    value.resume = previous
                    value.episodeID = UUID().uuidString
                    value.failures = 0
                }
            } else {
                value.episodeID = nil
            }
            value.mode = mode
            return pending
        }
        old?.cancel()
        await publish(mode, using: publishMode)
    }

    /// A new capture starts with no knowledge of the mode, and Signals are not replayed: publish it again.
    public func republish() async {
        let (mode, publishMode) = state.withLock { ($0.mode, $0.publishMode) }
        await publish(mode, using: publishMode)
    }

    private func publish(_ mode: ListeningMode, using publishMode: (@Sendable (ListeningMode) async throws -> Void)?)
        async
    {
        do { try await publishMode?(mode) } catch { report("Could not publish the listening mode: \(error)") }
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
        state.withLock { $0.mode == .quiet && $0.episodeID == episode && $0.judgmentID == id } && !Task.isCancelled
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

    /// Returns to the mode before `quiet`, then admits the sentence that ended it as ordinary user speech.
    private func leaveQuiet(_ text: String, _ input: AgentInput, episode: String, id: UUID) async {
        typealias Write = @Sendable (ListeningMode) async throws -> Void
        typealias Release = @Sendable (AgentInput) async throws -> Void
        let transition = state.withLock { value -> (ListeningMode, Write?, Release?)? in
            guard value.episodeID == episode, value.judgmentID == id, !Task.isCancelled else { return nil }
            // This task is the judgment; the mode change must not cancel it before the hand-off.
            value.judgment = nil
            value.judgmentID = nil
            // The route may have lost echo cancellation while quiet.
            return (
                value.resume == .full && value.fullDuplexSupported == false ? .half : value.resume,
                value.writeMode, value.release
            )
        }
        guard let (resume, writeMode, release) = transition else { return }
        do {
            guard let writeMode, let release else {
                throw CapabilityError.unavailable("Listening mode cannot be written")
            }
            try await writeMode(resume)
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

    /// A stopped perception session cancels the pending judgment and returns the variable to its default, so the next
    /// session does not silently start in `quiet`.
    public func perceptionEnded() async {
        let (pending, mode, writeMode) = state.withLock { value in
            value.fullDuplexSupported = nil
            return (value.retireJudgment(), value.mode, value.writeMode)
        }
        pending?.cancel()
        guard mode != .default else { return }
        do { try await writeMode?(.default) } catch CommunicationError.unavailableTarget {
            // The Assistant is already gone (shutdown); there is no variable left to reset.
        } catch { report("Could not reset the listening mode: \(error)") }
    }

    /// What the current capture reported about echo cancellation.
    public func captureDuplex(_ supported: Bool) async {
        typealias Write = @Sendable (ListeningMode) async throws -> Void
        let (current, writeMode, fellBack) = state.withLock { value -> (ListeningMode, Write?, Bool) in
            value.fullDuplexSupported = supported
            return (value.mode, value.writeMode, value.fellBack)
        }
        if supported {
            guard fellBack, current == .half else { return }
            do { try await writeMode?(.full) } catch { report("Could not return to full duplex: \(error)") }
            return
        }
        guard current == .full else { return }
        report("Full duplex is unavailable on this microphone route; listening is half duplex.")
        do {
            try await writeMode?(.half)
            state.withLock { $0.fellBack = true }
        } catch { report("Could not return to half duplex: \(error)") }
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
