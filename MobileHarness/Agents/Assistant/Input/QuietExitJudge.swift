import Foundation
import ModelKit

/// One model the exit judge may ask, in preference order. `chat` resolves the model when a request starts.
public struct QuietModelTier: Sendable {
    public let name: String
    public let modelID: String
    public let chat: @Sendable () async throws -> any ChatCapability
    public init(name: String, modelID: String, chat: @escaping @Sendable () async throws -> any ChatCapability) {
        self.name = name
        self.modelID = modelID
        self.chat = chat
    }
}

public struct QuietJudgement: Sendable, Equatable {
    public enum Decision: String, Sendable { case stay, exit }
    public let decision: Decision
    public let reason: String?
    public let tier: String
    public let modelID: String
    public let latencyMS: Int
}

public enum QuietExitError: Error, Equatable, Sendable {
    /// Every tier failed; the strings are the per-tier failures in order.
    case unavailable([String])
    case invalidAnswer
}

/// Judges the latest sentence against the current quiet episode's condition. Each call is one short
/// request, tried against each tier in order until one gives a valid answer.
public actor QuietExitJudge {
    public static let maximumSentenceCharacters = 512
    static let literalPrefix = "literal:"
    private let tiers: [QuietModelTier]
    private let language: @Sendable () -> String
    private let timeout: Duration

    public init(
        tiers: [QuietModelTier], language: @escaping @Sendable () -> String = { "en" }, timeout: Duration = .seconds(8)
    ) {
        self.tiers = tiers
        self.language = language
        self.timeout = timeout
    }

    public func judge(_ sentence: String, wakeCondition: String? = nil) async throws -> QuietJudgement {
        try Task.checkCancellation()
        var text = String(
            sentence.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumSentenceCharacters))
        if let wakeCondition, wakeCondition.hasPrefix(Self.literalPrefix) {
            let phrase = wakeCondition.dropFirst(Self.literalPrefix.count).trimmingCharacters(in: .whitespaces)
            guard !phrase.isEmpty else { throw AgentStateError.invalidValue("listening") }
            return .init(
                decision: text.contains(phrase) ? .exit : .stay, reason: nil,
                tier: "literal", modelID: "literal-match", latencyMS: 0)
        }
        if let wakeCondition {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            text = String(
                decoding: try encoder.encode(["latestUtterance": text, "wakeCondition": wakeCondition]), as: UTF8.self)
        }
        let instructions = try AgentPrompts.$language.withValue(AgentPrompts.normalizedLanguage(language())) {
            try AgentPrompts.text("Assistant/Input/QuietExit", wakeCondition == nil ? "instructions" : "conditioned")
        }
        let request = try ChatRequest(
            messages: [.init(role: .system, content: instructions), .init(role: .user, content: text)],
            maximumOutputTokens: 32, temperature: 0)
        var failures: [String] = []
        for tier in tiers {
            try Task.checkCancellation()
            let started = ContinuousClock.now
            do {
                let answer = try await ask(tier, request)
                let elapsed = started.duration(to: .now)
                let decision = try Self.parse(answer)
                return QuietJudgement(
                    decision: decision, reason: nil, tier: tier.name, modelID: tier.modelID,
                    latencyMS: Int(
                        elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(tier.name): \(error)")
            }
        }
        throw QuietExitError.unavailable(failures)
    }

    /// Accept one verdict so accompanying text cannot contradict the decision.
    static func parse(_ answer: String) throws -> QuietJudgement.Decision {
        let word = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let decision = QuietJudgement.Decision(rawValue: word) else { throw QuietExitError.invalidAnswer }
        return decision
    }

    private func ask(_ tier: QuietModelTier, _ request: ChatRequest) async throws -> String {
        let timeout = timeout
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let chat = try await tier.chat()
                let session = try await chat.chat(request)
                defer { session.cancel() }
                return try await session.withCleanup {
                    try await withTaskCancellationHandler {
                        var text = ""
                        var finished = false
                        for try await event in session.events {
                            try Task.checkCancellation()
                            switch event {
                            case .text(let delta): text += delta
                            case .usage: break
                            case .toolCall: throw QuietExitError.invalidAnswer
                            case .finished: finished = true
                            }
                        }
                        guard finished else { throw QuietExitError.invalidAnswer }
                        return text
                    } onCancel: {
                        session.cancel()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CapabilityError.unavailable("Quiet exit judgment timed out")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? ""
        }
    }
}
