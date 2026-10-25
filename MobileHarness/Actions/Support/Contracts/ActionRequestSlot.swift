import Foundation

public enum ActionRequestSlotError: Error, Sendable { case closed, invalidScope, duplicate, missingResult }
public actor ActionRequestSlot<Request: Sendable, Reply: Sendable> {
    public nonisolated let input: Request
    public nonisolated let requestID: String
    public nonisolated let sessionID: String
    private var admitted = false
    private var closed = false
    private var result: Reply?
    private var failure: (any Error)?
    public init(input: Request, requestID: String, sessionID: String) {
        self.input = input
        self.requestID = requestID
        self.sessionID = sessionID
    }
    public func accept(_ invocation: any FunctionInput) throws {
        guard !closed, !admitted, invocation.context.inputID == requestID,
            invocation.context.sessionID == sessionID
        else { throw ActionRequestSlotError.invalidScope }
        admitted = true
    }
    public func complete(_ reply: Reply) throws {
        try Task.checkCancellation()
        guard admitted, !closed, result == nil else { throw ActionRequestSlotError.duplicate }
        result = reply
    }
    public func fail(_ error: any Error) { if !closed { failure = error } }
    public func throwFailure() throws { if let failure { throw failure } }
    public func take() throws -> Reply {
        defer {
            closed = true
            result = nil
            failure = nil
        }
        if let failure { throw failure }
        guard !closed, let result else { throw ActionRequestSlotError.missingResult }
        return result
    }
    public func close() {
        closed = true
        result = nil
        failure = nil
    }
}
