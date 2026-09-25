/// Generation-local channel scope; closing a scope restores its parent or the action default.
struct ChannelParser: Sendable {
    private var stack: [String] = []
    var current: String? { stack.last }
    var isEmpty: Bool { stack.isEmpty }

    mutating func open(_ name: String) throws {
        guard CapabilityRegistry.validName(name) else { throw GenerationError.malformedMarkup }
        guard stack.count < 8 else { throw GenerationError.limitExceeded }
        stack.append(name)
    }

    mutating func close(_ name: String) throws {
        guard CapabilityRegistry.validName(name), stack.last == name else {
            throw GenerationError.malformedMarkup
        }
        stack.removeLast()
    }
}
