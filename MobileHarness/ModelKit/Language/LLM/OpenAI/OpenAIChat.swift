import Foundation
import ModelKit
import Synchronization

/// OpenAI-compatible text chat; the consumer contract is identical to local chat.
public actor OpenAIChat: ChatCapability {
    private let configuration: OpenAIChatConfiguration
    private let resource: ModelResource<Void>
    private let sessionConfiguration: @Sendable () -> URLSessionConfiguration

    public init(context: ModelContext, configuration: OpenAIChatConfiguration) throws {
        self.configuration = configuration
        resource = try context.resource {}
        sessionConfiguration = { .ephemeral }
    }

    init(
        context: ModelContext, configuration: OpenAIChatConfiguration,
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration
    ) throws {
        self.configuration = configuration
        resource = try context.resource {}
        self.sessionConfiguration = sessionConfiguration
    }

    /// Configured, not a claim that the remote service or credentials have been probed.
    public var availability: CapabilityAvailability { .available }

    public func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        let http = try configuration.request(request)
        let limits = try StreamLimits(capacity: nil, maximumEventBytes: 65568)
        let lease = try await resource.acquire()
        let control = RequestControl()
        let pair = InferenceSession<ChatEvent>.make(
            context: request.context, limits: limits, estimatedBytes: { $0.estimatedBytes },
            onTermination: { reason in
                if case .finished = reason { return }
                control.cancel()
            })
        let settings = sessionConfiguration()
        settings.timeoutIntervalForResource = configuration.timeout
        settings.httpCookieStorage = nil
        settings.urlCache = nil
        let network = URLSession(configuration: settings, delegate: NoRedirects(), delegateQueue: nil)
        let resource = resource
        let emitter = pair.emitter
        let task = Task {
            do {
                try Task.checkCancellation()
                let (bytes, response) = try await network.bytes(for: http)
                guard let response = response as? HTTPURLResponse else { throw OpenAIChatError.invalidResponse }
                guard (200..<300).contains(response.statusCode) else {
                    throw OpenAIChatError.httpStatus(response.statusCode)
                }
                guard response.mimeType?.lowercased() == "text/event-stream" else {
                    throw OpenAIChatError.invalidResponse
                }
                var decoder = ChatEventDecoder()
                var finish: ChatEvent?
                for try await byte in bytes {
                    try Task.checkCancellation()
                    for event in try decoder.consume(byte) {
                        if case .finished = event { finish = event } else { try emitter.yield(event) }
                    }
                    if decoder.finished { break }
                }
                guard let finish else { throw OpenAIChatError.truncatedStream }
                try Task.checkCancellation()
                network.invalidateAndCancel()
                await resource.release(lease.id)
                try emitter.yield(finish)
                emitter.finish()
            } catch {
                network.invalidateAndCancel()
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
        control.install(task)
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
        var task: Task<Void, Never>?
    }
    private let state = Mutex(State())
    func install(_ task: Task<Void, Never>) {
        let cancelled = state.withLock {
            $0.task = task
            return $0.cancelled
        }
        if cancelled { task.cancel() }
    }
    func cancel() {
        let task = state.withLock {
            $0.cancelled = true
            return $0.task
        }
        task?.cancel()
    }
}
