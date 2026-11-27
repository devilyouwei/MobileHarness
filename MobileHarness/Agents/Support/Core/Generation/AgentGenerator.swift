import Foundation

/// Shared model-output interpreter. It owns one parser and sentence buffer per generation.
public struct AgentGenerator: Sendable {
    public struct LocatedEvent: Sendable {
        public let event: GenerationEvent
        public let source: Range<Int>?

        public init(_ event: GenerationEvent, source: Range<Int>? = nil) {
            self.event = event
            self.source = source
        }
    }

    private let capabilities: CapabilityRegistry
    public typealias TextMapping = @Sendable (String) throws -> [GenerationEvent]
    private let mapTextCalls: TextMapping?
    private var parser: FunctionTokenParser
    private var sentences: SentenceFunctionBuffer
    private var sentenceSources: [Range<Int>] = []
    private var calls = 0
    private var waitDepth = 0
    private var pausedMilliseconds = 0
    private var closed = false

    public init(
        capabilities: CapabilityRegistry, textMapping: TextMapping? = nil,
        segmentation: TextSegmentationPolicy = .sentences,
        scopedActions: Set<String> = ["wait"]
    ) {
        sentences = SentenceFunctionBuffer(policy: segmentation)
        parser = FunctionTokenParser(scopedActions: scopedActions)
        self.capabilities = capabilities
        self.mapTextCalls = textMapping
    }

    public mutating func append(_ fragment: String) throws -> [GenerationEvent] {
        try append(Data(fragment.utf8))
    }

    public mutating func append(_ bytes: Data) throws -> [GenerationEvent] {
        try appendLocated(bytes).map(\.event)
    }

    public mutating func appendLocated(_ bytes: Data) throws -> [LocatedEvent] {
        guard !closed else { throw GenerationError.closed }
        do { return try interpret(parser.appendLocated(bytes)) } catch {
            closed = true
            throw error
        }
    }

    public mutating func finish() throws -> [GenerationEvent] {
        try finishLocated().map(\.event)
    }

    public mutating func finishLocated() throws -> [LocatedEvent] {
        guard !closed else { throw GenerationError.closed }
        do {
            var output = try interpret(parser.finishLocated())
            output += try flush()
            closed = true
            return output
        } catch {
            closed = true
            throw error
        }
    }

    /// Literal tool results/demo text never become markup or executable model instructions.
    public static func escapeText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private mutating func interpret(_ tokens: [FunctionTokenParser.LocatedToken]) throws -> [LocatedEvent] {
        var result: [LocatedEvent] = []
        for located in tokens {
            switch located.token {
            case .text(let text):
                guard mapTextCalls != nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw GenerationError.unknownCapability
                }
                sentenceSources += located.textSources
                result += try mapText(sentences.append(text))
            case .scope(let alias, let boundary):
                result += try flush()
                waitDepth += boundary == .start ? 1 : -1
                do {
                    if alias == "wait" {
                        guard capabilities.supportsWait else { throw GenerationError.unknownCapability }
                        result.append(
                            .init(.action(.init(actionPath: ActionCall.waitPath, channel: "Wait", scope: boundary))))
                    } else {
                        let call = try capabilities.resolveAction(alias, parameters: [:])
                        result.append(
                            .init(
                                .action(
                                    .init(
                                        actionPath: call.actionPath, channel: call.channel, parameters: call.parameters,
                                        scope: boundary))))
                    }
                } catch let error as GenerationError {
                    result.append(.init(.rejected(.init(kind: .action, alias: alias, reason: error))))
                }
            case .action(let alias, let parameters):
                result += try flush()
                try reserve(1)
                do {
                    if alias == "wait" {
                        guard case .pause(let milliseconds) = try capabilities.resolvePause(parameters) else {
                            throw GenerationError.invalidParameters
                        }
                        guard pausedMilliseconds + milliseconds <= CapabilityRegistry.maximumTotalPauseMilliseconds
                        else { throw GenerationError.limitExceeded }
                        pausedMilliseconds += milliseconds
                        result.append(
                            .init(
                                .action(
                                    .init(
                                        actionPath: ActionCall.waitPath, channel: "Wait",
                                        parameters: ["time": String(Double(milliseconds) / 1000)]))))
                        continue
                    }
                    if capabilities.isControl(alias) {
                        guard waitDepth == 0 else { throw GenerationError.controlInsideWait }
                        result.append(.init(.control(try capabilities.resolveControl(alias, parameters: parameters))))
                    } else {
                        result.append(
                            .init(
                                .action(try capabilities.resolveAction(alias, parameters: parameters)),
                                source: located.source))
                    }
                } catch let error as GenerationError
                    where error == .unknownCapability || error == .invalidParameters || error == .controlInsideWait
                    || (alias == "wait" && error == .limitExceeded)
                {
                    result.append(
                        .init(
                            .rejected(
                                CallRejection(
                                    kind: capabilities.isControl(alias) ? .control : .action, alias: alias,
                                    reason: error))))
                }
            }
        }
        return result
    }

    private mutating func flush() throws -> [LocatedEvent] {
        defer { sentenceSources.removeAll() }
        return try mapText(sentences.finish())
    }

    private mutating func mapText(_ chunks: [String]) throws -> [LocatedEvent] {
        var output: [LocatedEvent] = []
        for chunk in chunks {
            guard let mapTextCalls else { throw GenerationError.unknownCapability }
            let calls = try mapTextCalls(chunk)
            guard !calls.isEmpty, calls.count <= 8 else { throw GenerationError.limitExceeded }
            try reserve(calls.count)
            let span = sentenceSources.prefix(chunk.unicodeScalars.count)
            guard span.count == chunk.unicodeScalars.count, let first = span.first, let last = span.last else {
                throw GenerationError.invalidUTF8
            }
            let source = first.lowerBound..<last.upperBound
            sentenceSources.removeFirst(span.count)
            output += calls.map { event in
                if case .action(let call) = event { return .init(.runtimeAction(call), source: source) }
                return .init(event, source: source)
            }
        }
        return output
    }

    private mutating func reserve(_ count: Int) throws {
        guard calls + count <= 120 else { throw GenerationError.limitExceeded }
        calls += count
    }
}
