import Foundation
@_spi(ModelManagement) import ModelKit

/// Process-owned IoC container in production; isolated construction is assembly/test SPI. Owns registration, provider identity and weight lifecycle.
public actor ModelManager {
    private final class Entry {
        let registration: ModelRegistration
        var context: ModelContext
        var constructed = false
        var construction: (id: UUID, task: Task<ProvidedCapabilities, Error>)?
        var waiters = 0
        var unloading = false
        init(_ registration: ModelRegistration, gate: ModelLoadGate) {
            self.registration = registration
            context = ModelContext(loadGate: gate)
        }
    }
    private let loadGate = ModelLoadGate()
    private var entries: [ModelID: Entry] = [:]
    private var defaults: [ProvidedCapability: ModelID] = [:]
    private var constructing = 0
    private var closed = false
    private var shutdownTask: Task<Void, Never>?
    @_spi(ModelAssembly) public init() {}

    @_spi(ModelAssembly) public func register(
        _ registration: ModelRegistration, defaults selected: Set<ProvidedCapability> = []
    ) throws {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard entries[registration.id] == nil else { throw ModelRegistrationError.duplicateModel(registration.id) }
        guard entries.count < 32 else { throw CapabilityError.inputBusy }
        guard selected.isSubset(of: registration.capabilities) else { throw ModelRegistrationError.invalidRegistration }
        for capability in selected where defaults[capability] != nil {
            throw ModelRegistrationError.duplicateDefault(capability)
        }
        entries[registration.id] = Entry(registration, gate: loadGate)
        for capability in selected { defaults[capability] = registration.id }
    }

    public func get<Value: Sendable>(_ key: CapabilityKey<Value>, load: Bool = true) async throws -> Value {
        try await get(defaultID(for: key.kind), as: key, load: load)
    }

    public func load(_ capability: ProvidedCapability) async throws { try await load(defaultID(for: capability)) }
    public func warmup(_ capability: ProvidedCapability) async throws { try await warmup(defaultID(for: capability)) }
    public func unload(_ capability: ProvidedCapability) async throws { try await unload(defaultID(for: capability)) }
    public func status(_ capability: ProvidedCapability) async throws -> ModelState {
        try await status(defaultID(for: capability))
    }
    public func availability(_ capability: ProvidedCapability) async throws -> CapabilityAvailability {
        try await availability(defaultID(for: capability), for: capability)
    }
    private func defaultID(for capability: ProvidedCapability) throws -> ModelID {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard let id = defaults[capability] else { throw ModelRegistrationError.missingDefault(capability) }
        return id
    }

    public func status(_ id: ModelID) async throws -> ModelState {
        if closed { return .closed }
        let entry = try entry(id)
        if entry.unloading { return .unloading }
        if !entry.constructed { return entry.construction == nil ? .registered : .constructing }
        return await entry.context.status
    }

    /// Defaults to ready-to-use resources. Deferred acquisition is for lazy App composition.
    public func get<Value: Sendable>(
        _ id: ModelID, as key: CapabilityKey<Value>, load: Bool = true
    ) async throws -> Value {
        let capabilities = try await get(id, requiring: key.kind, load: load)
        guard let value = key.select(capabilities) else { throw ModelRegistrationError.factoryContractMismatch }
        return value
    }

    func get(_ id: ModelID, requiring capability: ProvidedCapability, load: Bool = true) async throws
        -> ProvidedCapabilities
    {
        let entry = try entry(id)
        guard entry.registration.capabilities.contains(capability) else {
            throw ModelRegistrationError.unsupportedCapability(capability)
        }
        let result = try await construct(entry)
        if load { try await entry.context.load() }
        try Task.checkCancellation()
        guard !closed, !entry.unloading else {
            throw CapabilityError.unavailable("Model is unavailable during teardown")
        }
        return result
    }

    /// Availability is a snapshot separate from weight residency. Does not load weights.
    public func availability(_ id: ModelID, for capability: ProvidedCapability) async throws -> CapabilityAvailability {
        let provider = try await get(id, requiring: capability, load: false)
        return await provider.availability(for: capability)
    }

    /// Best effort, no waiting or inference cancellation. Only explicitly eligible idle models are evicted.
    @discardableResult
    public func handleMemoryPressure() async -> [ModelID] {
        guard !closed else { return [] }
        var released: [ModelID] = []
        for entry in Array(entries.values) {
            guard entry.registration.memoryPolicy == .releaseWhenIdle,
                entry.constructed, !entry.unloading
            else { continue }
            entry.unloading = true
            let unloaded = await entry.context.unloadIfIdle()
            entry.unloading = false
            if unloaded { released.append(entry.registration.id) }
        }
        return released
    }

    public func load(_ id: ModelID) async throws {
        let entry = try entry(id)
        _ = try await construct(entry)
        try await entry.context.load()
        try Task.checkCancellation()
        guard !closed, !entry.unloading else { throw CapabilityError.sessionClosed }
    }

    public func warmup(_ id: ModelID) async throws {
        let entry = try entry(id)
        let provider = try await construct(entry)
        try await entry.context.load()
        try Task.checkCancellation()
        guard !closed, !entry.unloading else { throw CapabilityError.sessionClosed }
        try await provider.warmup?()
        try Task.checkCancellation()
        guard !closed, !entry.unloading else { throw CapabilityError.sessionClosed }
    }

    public func unload(_ id: ModelID) async throws {
        let entry = try entry(id)
        // Reserve before any await so get/load cannot cross the transition.
        guard !entry.unloading else { throw CapabilityError.inputBusy }
        entry.unloading = true
        defer { entry.unloading = false }
        if let task = entry.construction?.task { _ = try await task.value }
        try await entry.context.unload()
    }

    /// Terminal: close admission, cancel active sessions and join backend cleanup.
    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        closed = true
        let work = entries.values.map { ($0.context, $0.construction?.task) }
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for (context, construction) in work {
                    group.addTask {
                        construction?.cancel()
                        if let construction { _ = try? await construction.value }
                        await context.shutdown()
                    }
                }
            }
        }
        shutdownTask = task
        await task.value
    }

    private func entry(_ id: ModelID) throws -> Entry {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard let entry = entries[id] else { throw ModelRegistrationError.unknownModel(id) }
        return entry
    }

    private func construct(_ entry: Entry) async throws -> ProvidedCapabilities {
        try Task.checkCancellation()
        guard !entry.unloading else { throw CapabilityError.unavailable("Model is unloading") }
        guard entry.waiters < 32 else { throw CapabilityError.inputBusy }
        entry.waiters += 1
        defer { entry.waiters -= 1 }
        if entry.construction == nil {
            guard constructing < 4 else { throw CapabilityError.inputBusy }
            constructing += 1
            let registration = entry.registration
            let context = entry.context
            let id = UUID()
            let task = Task {
                do {
                    let result = try await registration.factory(context)
                    guard result.supported == registration.capabilities else {
                        throw ModelRegistrationError.factoryContractMismatch
                    }
                    context.seal()
                    entry.constructed = true
                    self.constructing -= 1
                    return result
                } catch {
                    await context.shutdown()
                    self.constructing -= 1
                    if entry.construction?.id == id {
                        entry.construction = nil
                        entry.context = ModelContext(loadGate: self.loadGate)
                    }
                    throw error
                }
            }
            entry.construction = (id, task)
        }
        let construction = entry.construction!
        let result = try await construction.task.value
        try Task.checkCancellation()
        guard !closed, !entry.unloading else {
            throw CapabilityError.unavailable("Model is unavailable during teardown")
        }
        return result
    }

}

/// Typed selection avoids exposing Any or concrete backends to consumers.
public struct CapabilityKey<Value: Sendable>: Sendable {
    let kind: ProvidedCapability
    let select: @Sendable (ProvidedCapabilities) -> Value?
}
extension CapabilityKey where Value == any ChatCapability {
    public static var chat: Self { Self(kind: .chat, select: { $0.chat }) }
}
extension CapabilityKey where Value == any SpeechRecognitionCapability {
    public static var recognition: Self { Self(kind: .recognition, select: { $0.recognition }) }
}
extension CapabilityKey where Value == any SpeechSynthesisCapability {
    public static var synthesis: Self { Self(kind: .synthesis, select: { $0.synthesis }) }
}
extension CapabilityKey where Value == any VoiceActivityCapability {
    public static var voiceActivity: Self { Self(kind: .voiceActivity, select: { $0.voiceActivity }) }
}
extension CapabilityKey where Value == any JudgeCapability {
    public static var judge: Self { Self(kind: .judge, select: { $0.judge }) }
}
