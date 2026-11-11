import Foundation
import ModelKit
import Synchronization

/// OpenAI-compatible text chat; the consumer contract is identical to local chat.
public actor OpenAIChat: ChatCapability {
    private let configuration: OpenAIChatConfiguration
    private let resource: ModelResource<ChatNetworkSession>

    public init(context: ModelContext, configuration: OpenAIChatConfiguration) throws {
        self.configuration = configuration
        resource = try context.resource(concurrent: true) {
            ChatNetworkSession(configuration: .ephemeral, timeout: configuration.timeout)
        }
    }

    init(
        context: ModelContext, configuration: OpenAIChatConfiguration,
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration
    ) throws {
        self.configuration = configuration
        resource = try context.resource(concurrent: true) {
            ChatNetworkSession(configuration: sessionConfiguration(), timeout: configuration.timeout)
        }
    }

    /// Configured, not a claim that the remote service or credentials have been probed.
    public var supportsToolCalls: Bool { true }
    public var supportsImages: Bool { true }

    public var availability: CapabilityAvailability { .available }

    public func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        let http = try configuration.request(request)
        let limits = try StreamLimits(capacity: 128, maximumEventBytes: nil)
        let lease = try await resource.acquire()
        let control = RequestControl()
        let pair = InferenceSession<ChatEvent>.make(
            context: request.context, limits: limits, estimatedBytes: { $0.estimatedBytes },
            onTermination: { reason in
                if case .finished = reason { return }
                control.cancel()
            }, waitForCompletion: { await control.waitForCompletion() })
        let network = lease.model.session
        let resource = resource
        let emitter = pair.emitter
        let task = Task {
            defer { control.finish() }
            var transportStage = ChatFailureDiagnostic.Stage.http
            var capture = HTTPByteCapture(sink: request.transportCapture)
            do {
                try Task.checkCancellation()
                try await request.onDispatch?()
                request.timing?.start()
                await request.transportCapture?(
                    .request(
                        method: http.httpMethod ?? "GET", url: HTTPLogSanitizer.url(http.url),
                        headers: HTTPLogSanitizer.headers(http.allHTTPHeaderFields ?? [:]),
                        body: http.httpBody ?? Data(), at: Date()))
                let (bytes, response) = try await network.bytes(for: http)
                control.installHTTP(bytes.task)
                guard let response = response as? HTTPURLResponse else {
                    throw OpenAIChatError.responseFailure(.init(.invalidHTTPResponse, stage: .http))
                }
                await request.transportCapture?(
                    .response(
                        status: response.statusCode,
                        headers: HTTPLogSanitizer.headers(
                            Dictionary(
                                uniqueKeysWithValues: response.allHeaderFields.map {
                                    (String(describing: $0.key), String(describing: $0.value))
                                })), at: Date()))
                if !(200..<300).contains(response.statusCode) || response.mimeType?.lowercased() != "text/event-stream"
                {
                    var diagnosticBody = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        await capture.append(byte)
                        if diagnosticBody.count < 16_384 { diagnosticBody.append(byte) }
                    }
                    await capture.finish(error: nil)
                    if !(200..<300).contains(response.statusCode) {
                        throw configuration.httpFailure(response, body: diagnosticBody)
                    }
                    throw OpenAIChatError.responseFailure(.init(.unexpectedContentType, stage: .http))
                }
                transportStage = .stream
                var decoder = ChatEventDecoder(
                    toolNames: OpenAIChatConfiguration.toolNames(request.tools), timing: request.timing)
                var finish: ChatEvent?
                for try await byte in bytes {
                    try Task.checkCancellation()
                    await capture.append(byte)
                    for event in try decoder.consume(byte) {
                        if case .text(let delta) = event { request.timing?.recordText(delta) }
                        if case .finished = event { finish = event } else { try await emitter.yieldSuspending(event) }
                    }
                }
                await capture.finish(error: nil)
                guard let finish else { throw OpenAIChatError.truncatedStream }
                try Task.checkCancellation()
                try await emitter.yieldSuspending(finish)
                await resource.release(lease.id)
                emitter.finish()
            } catch {
                await capture.finish(error: Task.isCancelled ? "cancelled" : "Transport or parsing stopped before EOF")
                control.cancelHTTP()
                await resource.release(lease.id)
                if Task.isCancelled || error is CancellationError {
                    emitter.fail(CancellationError())
                } else if error is OpenAIChatError || error is CapabilityError {
                    emitter.fail(error)
                } else {
                    emitter.fail(OpenAIChatError.transportFailure(error, stage: transportStage))
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
    func waitForCompletion() async { await worker.waitForCompletion() }
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
final class ChatNetworkSession: Sendable {
    let session: URLSession
    init(configuration: URLSessionConfiguration, timeout: TimeInterval) {
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
}

/// One 64 KiB chunk per request; awaiting the sink supplies backpressure without an unbounded queue.
private struct HTTPByteCapture {
    let sink: (@Sendable (ChatTransportEvent) async -> Void)?
    private var buffer = Data()
    private var firstByte: Date?
    private var ended = false
    init(sink: (@Sendable (ChatTransportEvent) async -> Void)?) { self.sink = sink }
    mutating func append(_ byte: UInt8) async {
        guard sink != nil, !ended else { return }
        if buffer.isEmpty { firstByte = Date() }
        buffer.append(byte)
        if buffer.count == 65_536 { await flush() }
    }
    private mutating func flush() async {
        guard !buffer.isEmpty, let firstByte else { return }
        await sink?(.bytes(buffer, at: firstByte))
        buffer.removeAll(keepingCapacity: true)
        self.firstByte = nil
    }
    mutating func finish(error: String?) async {
        guard !ended else { return }
        await flush()
        ended = true
        await sink?(.finished(at: Date(), error: error))
    }
}

private enum HTTPLogSanitizer {
    static func sensitive(_ name: String) -> Bool {
        let key = name.lowercased()
        return ["authorization", "cookie", "key", "token", "secret", "password", "credential", "signature"].contains {
            key.contains($0)
        }
    }
    static func headers(_ values: [String: String]) -> [String: String] {
        values.mapValues { $0 }.reduce(into: [:]) { result, entry in
            result[entry.key] = sensitive(entry.key) ? "[redacted]" : entry.value
        }
    }
    static func url(_ url: URL?) -> String {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        parts.user = nil
        parts.password = nil
        parts.queryItems = parts.queryItems?.map {
            sensitive($0.name) ? URLQueryItem(name: $0.name, value: "[redacted]") : $0
        }
        return parts.string ?? ""
    }
}
