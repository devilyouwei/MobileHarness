import Foundation
import ModelKit
import ModelKitOpenAI
@_spi(ModelAssembly) import ModelKitRuntime

#if !targetEnvironment(simulator)
    import ModelKitGemma4
#endif

extension DefaultModelAssembly {
    @available(iOS 27, macOS 27, *)
    static func chatRegistration(resources: URL, configuration: OpenAIChatConfiguration?, id: ModelID = ModelID("chat"))
        throws
        -> ModelRegistration
    {
        try ModelRegistration(
            id: id, capabilities: [.chat], memoryPolicy: .releaseWhenIdle,
            artifactID: configuration == nil ? "gemma4-e2b" : nil
        ) { context in
            if let configuration {
                return ProvidedCapabilities(chat: try OpenAIChat(context: context, configuration: configuration))
            }
            #if targetEnvironment(simulator)
                return ProvidedCapabilities(chat: UnsupportedChat())
            #else
                let model = try Gemma4Chat(context: context, artifacts: resources.appendingPathComponent("Gemma4"))
                return ProvidedCapabilities(warmup: { try await model.warmup() }, chat: model)
            #endif
        }
    }

}

#if targetEnvironment(simulator)
    private struct UnsupportedChat: ChatCapability {
        var availability: CapabilityAvailability { .unavailable(reason: "Gemma 4 CoreAI requires a physical device") }
        func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
            throw CapabilityError.unavailable("Gemma 4 CoreAI requires a physical device")
        }
    }

#endif

/// Root-owned local LLM execution; queued sessions hold no native inference resources.
actor SerialChat {
    private struct Job: Sendable {
        let id: UUID
        let request: ChatRequest
        let emitter: InferenceEmitter<ChatEvent>
        let control: InferenceTaskControl
    }
    private let maximumPending: Int
    private let model: @Sendable () async throws -> any ChatCapability
    private var pending: [Job] = []
    private var active: Job?
    private var stopping = false
    init(maximumPending: Int, model: @escaping @Sendable () async throws -> any ChatCapability) throws {
        guard maximumPending >= 0 else { throw CapabilityError.invalidRequest("Invalid local chat queue capacity") }
        self.maximumPending = maximumPending
        self.model = model
    }
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        try Task.checkCancellation()
        guard !stopping else { throw CancellationError() }
        pruneCancelled()
        guard active == nil || pending.count < maximumPending else { throw CapabilityError.inputBusy }
        let id = UUID()
        let control = InferenceTaskControl()
        let pair = InferenceSession<ChatEvent>.make(
            context: request.context, limits: try StreamLimits(capacity: 128, maximumEventBytes: nil),
            estimatedBytes: { $0.estimatedBytes },
            onTermination: { reason in
                if case .finished = reason { return }
                control.cancel()
                Task { await self.cancel(id) }
            }, phase: .queued, waitForCompletion: { await control.waitForCompletion() })
        let job = Job(id: id, request: request, emitter: pair.emitter, control: control)
        pending.append(job)
        next()
        return pair.session
    }
    private func pruneCancelled() {
        pending.removeAll { job in
            if job.control.isCancelled {
                job.control.finish()
                return true
            }
            return false
        }
    }
    private func next() {
        pruneCancelled()
        guard !stopping, active == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        active = job
        let task = Task { await self.run(job) }
        do { try job.control.install(task) } catch { job.emitter.fail(error) }
    }
    private func run(_ job: Job) async {
        var child: InferenceSession<ChatEvent>?
        do {
            try Task.checkCancellation()
            job.emitter.markRunning()
            let capability = try await model()
            let session = try await capability.chat(job.request)
            child = session
            for try await event in session.events { try await job.emitter.yieldSuspending(event) }
            await session.waitForCompletion()
            try Task.checkCancellation()
            job.emitter.finish()
        } catch {
            child?.cancel()
            await child?.waitForCompletion()
            job.emitter.fail(error)
        }
        job.control.finish()
        if active?.id == job.id { active = nil }
        next()
    }
    private func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            let job = pending.remove(at: index)
            job.emitter.fail(CancellationError())
            job.control.finish()
        } else if active?.id == id {
            active?.control.cancel()
        }
    }
    func cancelAll() async {
        stopping = true
        let jobs = pending
        pending.removeAll()
        for job in jobs {
            job.emitter.fail(CancellationError())
            job.control.finish()
        }
        let running = active
        running?.control.cancel()
        await running?.control.waitForCompletion()
        stopping = false
    }
}
