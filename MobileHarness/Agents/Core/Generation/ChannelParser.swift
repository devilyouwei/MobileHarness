/// One lexical stack prevents crossing Channel/wait scopes. Wait never changes the effective channel.
struct ChannelParser: Sendable {
    private enum Scope: Equatable {
        case channel(String)
        case wait
    }
    private var stack: [Scope] = []
    private var waits = 0
    var current: String? {
        for scope in stack.reversed() { if case .channel(let name) = scope { return name } }
        return nil
    }
    var isEmpty: Bool { stack.isEmpty }

    mutating func open(_ name: String) throws {
        guard CapabilityRegistry.validName(name) else { throw GenerationError.malformedMarkup }
        try push(.channel(name))
    }
    mutating func close(_ name: String) throws { try pop(.channel(name)) }
    mutating func openWait() throws {
        guard waits < 32 else { throw GenerationError.limitExceeded }
        try push(.wait)
        waits += 1
    }
    mutating func closeWait() throws { try pop(.wait) }
    private mutating func push(_ scope: Scope) throws {
        guard stack.count < 8 else { throw GenerationError.limitExceeded }
        stack.append(scope)
    }
    private mutating func pop(_ scope: Scope) throws {
        guard stack.last == scope else { throw GenerationError.malformedMarkup }
        stack.removeLast()
    }
}
