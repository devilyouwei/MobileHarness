import Foundation
import ModelKit
import Synchronization

/// OpenAI-compatible text chat; the consumer contract is identical to local chat.
public actor OpenAIChat: ChatCapability {
    private let configuration: OpenAIChatConfiguration
    private let resource: ModelResource<ChatNetworkSession>

    public init(context: ModelContext, configuration: OpenAIChatConfiguration) throws {
        self.configuration = configuration
        resource = try context.resource {
            ChatNetworkSession(configuration: .ephemeral, timeout: configuration.timeout)
        }
    }

    init(
        context: ModelContext, configuration: OpenAIChatConfiguration,
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration
    ) throws {
        self.configuration = configuration
        resource = try context.resource {
            ChatNetworkSession(configuration: sessionConfiguration(), timeout: configuration.timeout)
        }
    }

    /// Configured, not a claim that the remote service or credentials have been probed.
    public var supportsToolCalls: Bool { true }
    public var supportsImages: Bool { true }

    public var availability: CapabilityAvailability { .available }

    public func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        let http = try configuration.request(request)
        let limits = try StreamLimits(capacity: 128, maximumEventBytes: 65568)
        let lease = try await resource.acquire()
        let control = RequestControl()
        let pair = InferenceSession<ChatEvent>.make(
            context: request.context, limits: limits, estimatedBytes: { $0.estimatedBytes },
            onTermination: { reason in
                if case .finished = reason { return }
                control.cancel()
            })
        let network = lease.model.session
        let resource = resource
        let emitter = pair.emitter
        let task = Task {
            defer { control.finish() }
            do {
                try Task.checkCancellation()
                request.timing?.start()
                let (bytes, response) = try await network.bytes(for: http)
                control.installHTTP(bytes.task)
                guard let response = response as? HTTPURLResponse else { throw OpenAIChatError.invalidResponse }
                guard (200..<300).contains(response.statusCode) else {
                    throw OpenAIChatError.httpStatus(response.statusCode)
                }
                guard response.mimeType?.lowercased() == "text/event-stream" else {
                    throw OpenAIChatError.invalidResponse
                }
                var decoder = ChatEventDecoder(
                    toolNames: OpenAIChatConfiguration.toolNames(request.tools), timing: request.timing)
                var finish: ChatEvent?
                for try await byte in bytes {
                    try Task.checkCancellation()
                    for event in try decoder.consume(byte) {
                        if case .text(let delta) = event { request.timing?.recordText(delta) }
                        if case .finished = event { finish = event } else { try await emitter.yieldSuspending(event) }
                    }
                }
                guard let finish else { throw OpenAIChatError.truncatedStream }
                try Task.checkCancellation()
                try await emitter.yieldSuspending(finish)
                await resource.release(lease.id)
                emitter.finish()
            } catch {
                control.cancelHTTP()
                await resource.release(lease.id)
                if Task.isCancelled || error is CancellationError {
                    emitter.fail(CancellationError())
                } else if error is OpenAIChatError || error is CapabilityError {
                    emitter.fail(error)
                } else {
                    emitter.fail(OpenAIChatError.transport)
                }
            }
        }
        try control.install(task)
        await resource.setCancellation(lease.id) { [weak session = pair.session] in session?.cancel() }
        return pair.session
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

private final class RequestControl: Sendable {
    private struct State {
        var cancelled = false
        var http: URLSessionTask?
    }
    private let state = Mutex(State())
    private let worker = InferenceTaskControl()
    func install(_ task: Task<Void, Never>) throws { try worker.install(task) }
    func finish() {
        worker.finish()
        state.withLock { $0.http = nil }
    }
    func installHTTP(_ task: URLSessionTask) {
        let cancelled = state.withLock {
            $0.http = task
            return $0.cancelled
        }
        if cancelled { task.cancel() }
    }
    func cancelHTTP() { state.withLock { $0.http }?.cancel() }
    func cancel() {
        worker.cancel()
        state.withLock { $0.cancelled = true }
        cancelHTTP()
    }
}

/// Resource residency owns connection reuse and final teardown, independently of any request.
private final class ChatNetworkSession: Sendable {
    let session: URLSession
    init(configuration: URLSessionConfiguration, timeout: TimeInterval) {
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
}
