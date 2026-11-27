import Foundation
import Synchronization

/// Internal Signal (Agent–Agent send): a neutral, typed request/reply contract. Registration supplies real handlers, never role routing.
public struct SignalRequestProtocol<Request: Sendable, Reply: Sendable>: Sendable {
    public let id: String
    public let maximumRequestBytes: Int
    public let maximumReplyBytes: Int
    public let timeout: Duration
    let requestSize: @Sendable (Request) throws -> Int
    let replySize: @Sendable (Reply) throws -> Int

    public init(
        id: String, maximumRequestBytes: Int, maximumReplyBytes: Int, timeout: Duration = .seconds(30),
        requestSize: @escaping @Sendable (Request) throws -> Int,
        replySize: @escaping @Sendable (Reply) throws -> Int
    ) throws {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard id.utf8.count <= 64, (3...6).contains(parts.count),
            parts.dropLast().allSatisfy({ part in
                guard let first = part.utf8.first, (97...122).contains(first) else { return false }
                return part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
            }), let version = parts.last, version.first == "v", version.dropFirst().first != "0",
            !version.dropFirst().isEmpty, version.dropFirst().utf8.allSatisfy({ (48...57).contains($0) }),
            (1...4_194_304).contains(maximumRequestBytes), (1...4_194_304).contains(maximumReplyBytes),
            timeout > .zero, timeout <= .seconds(120)
        else { throw SignalTransportError.invalidEnvelope }
        self.id = id
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumReplyBytes = maximumReplyBytes
        self.timeout = timeout
        self.requestSize = requestSize
        self.replySize = replySize
    }
}

public struct SignalRequestContext: Sendable {
    public let source: SignalEndpoint
    public let target: SignalEndpoint
    public let protocolID: String
    public let envelope: SignalEnvelope
}

struct SignalRequestHandler: Sendable {
    let maximumRequestBytes: Int
    let maximumReplyBytes: Int
    let timeout: Duration
    let measureRequest: @Sendable (any Sendable) throws -> Int
    let requestType: ObjectIdentifier
    let replyType: ObjectIdentifier
    let operation: @Sendable (any Sendable, SignalRequestContext) async throws -> any Sendable
}

struct SignalRequestInvocation: Sendable {
    let operation: @Sendable () async throws -> Void
}

final class SignalReplyBox<Value: Sendable>: Sendable {
    private let storage = Mutex<Value?>(nil)
    func store(_ value: Value) { storage.withLock { $0 = value } }
    func result() throws -> Value {
        try storage.withLock {
            guard let result = $0 else { throw SignalTransportError.invalidReply }
            return result
        }
    }
}

enum SignalRequestChain {
    @TaskLocal static var endpoints: [String] = []
}

extension SignalTransport {
    /// Binding a handler neither activates a receiver nor grants business permissions.
    public func registerRequest<Request, Reply>(
        _ descriptor: SignalRequestProtocol<Request, Reply>, endpoint: SignalEndpoint,
        handler: @escaping @Sendable (Request) async throws -> Reply
    ) throws {
        try registerContextualRequest(descriptor, endpoint: endpoint) { value, _ in try await handler(value) }
    }
    public func registerContextualRequest<Request, Reply>(
        _ descriptor: SignalRequestProtocol<Request, Reply>, endpoint: SignalEndpoint,
        handler: @escaping @Sendable (Request, SignalRequestContext) async throws -> Reply
    ) throws {
        try validateRequestEndpoint(endpoint)
        guard requestHandlers[endpoint]?[descriptor.id] == nil else { throw SignalTransportError.duplicateProtocol }
        guard (requestHandlers[endpoint]?.count ?? 0) < 32 else { throw SignalTransportError.capacityExceeded }
        requestHandlers[endpoint, default: [:]][descriptor.id] = SignalRequestHandler(
            maximumRequestBytes: descriptor.maximumRequestBytes, maximumReplyBytes: descriptor.maximumReplyBytes,
            timeout: descriptor.timeout,
            measureRequest: { value in
                guard let value = value as? Request else { throw SignalTransportError.schemaMismatch }
                return try descriptor.requestSize(value)
            }, requestType: ObjectIdentifier(Request.self), replyType: ObjectIdentifier(Reply.self),
            operation: { value, context in
                guard let request = value as? Request else { throw SignalTransportError.schemaMismatch }
                let size = try descriptor.requestSize(request)
                guard size >= 0, size <= descriptor.maximumRequestBytes else {
                    throw SignalTransportError.invalidEnvelope
                }
                let reply = try await handler(request, context)
                let replySize = try descriptor.replySize(reply)
                guard replySize >= 0, replySize <= descriptor.maximumReplyBytes else {
                    throw SignalTransportError.invalidReply
                }
                return reply
            })
    }

    public func request<Request, Reply>(
        source: SignalEndpoint, target: SignalEndpoint, using descriptor: SignalRequestProtocol<Request, Reply>,
        request: Request, envelope: SignalEnvelope? = nil
    ) async throws -> Reply {
        try Task.checkCancellation()
        try validateRequestEndpoint(source)
        try validateRequestEndpoint(target)
        guard let handler = requestHandlers[target]?[descriptor.id] else {
            throw SignalTransportError.unsupportedProtocol
        }
        guard handler.requestType == ObjectIdentifier(Request.self), handler.replyType == ObjectIdentifier(Reply.self),
            handler.maximumRequestBytes == descriptor.maximumRequestBytes,
            handler.maximumReplyBytes == descriptor.maximumReplyBytes,
            handler.timeout == descriptor.timeout
        else { throw SignalTransportError.schemaMismatch }
        let chain = SignalRequestChain.endpoints.isEmpty ? [source.address] : SignalRequestChain.endpoints
        guard chain.count < 8, !chain.contains(target.address) else { throw SignalTransportError.cyclicRequest }
        let size = try handler.measureRequest(request)
        guard size >= 0, size <= descriptor.maximumRequestBytes else { throw SignalTransportError.invalidEnvelope }
        let box = SignalReplyBox<Reply>()
        let metadata =
            envelope
            ?? SignalEnvelope(
                id: UUID().uuidString, sessionID: source.incarnation, contract: descriptor.id, payloadBytes: size)
        guard metadata.contract == descriptor.id else { throw SignalTransportError.schemaMismatch }
        try validateEnvelope(metadata)
        let timeout = ContinuousClock.now.advanced(by: descriptor.timeout)
        let deadline = metadata.expiresAt.map { min($0, timeout) } ?? timeout
        let requestEnvelope = SignalEnvelope(
            id: metadata.id, sessionID: metadata.sessionID, contract: descriptor.id, channel: metadata.channel,
            version: metadata.version, hops: metadata.hops, payloadBytes: size + descriptor.maximumReplyBytes,
            expiresAt: deadline, cleanup: metadata.cleanup, control: metadata.control)
        let invocation = SignalRequestInvocation {
            let value = try await handler.operation(
                request, .init(source: source, target: target, protocolID: descriptor.id, envelope: requestEnvelope))
            guard let reply = value as? Reply else { throw SignalTransportError.invalidReply }
            let replyBytes = try descriptor.replySize(reply)
            guard replyBytes >= 0, replyBytes <= descriptor.maximumReplyBytes else {
                throw SignalTransportError.invalidReply
            }
            box.store(reply)
        }
        try await SignalRequestChain.$endpoints.withValue(chain + [target.address]) {
            try await self.send(
                source: source, target: target, envelope: requestEnvelope, payload: invocation,
                timeout: descriptor.timeout)
        }
        try Task.checkCancellation()
        try validateRequestEndpoint(source)
        try validateRequestEndpoint(target)
        guard ContinuousClock.now < deadline else { throw SignalTransportError.expired }
        return try box.result()
    }
}
