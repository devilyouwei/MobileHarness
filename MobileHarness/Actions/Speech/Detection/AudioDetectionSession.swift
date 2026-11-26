import Foundation
import FunctionContracts
import PlatformKit
import UI

/// Agent-owned diagnostic role graph. No capture control or media forwarding.
@MainActor public final class AudioDetectionSession: AudioDetectionRunning {
    private let connections: AudioDetectionConnections
    private let execution: AudioDetectionExecution
    private let keywordTest: Bool
    private var active = false
    public init(connections: AudioDetectionConnections, execution: AudioDetectionExecution, keywordTest: Bool = false) {
        self.connections = connections
        self.execution = execution
        self.keywordTest = keywordTest
    }
    public func run(update: @escaping @MainActor @Sendable (AudioDetectionSnapshot) -> Void) async throws {
        guard !active else { throw AudioDetectionError.busy }
        let makePerception = keywordTest ? connections.makeKeywordPerception : connections.makePerception
        guard let makePerception else { throw AudioDetectionError.keywordModelNotReady }
        active = true
        defer { active = false }
        let prepared = try await execution.prepare(update: update)
        do {
            try await withTaskCancellationHandler {
                let observe: @MainActor (AudioDetectionObservation) -> Void = { prepared.observe($0) }
                let fail: @MainActor (any Error) async -> Void = { await prepared.fail($0) }
                let perception = try await makePerception(prepared.id, prepared.input, observe, fail)
                try await prepared.install(perception)
                try await execution.run(prepared, preferSpatial: !keywordTest)
            } onCancel: {
                Task { await prepared.shutdown() }
            }
        } catch {
            try await prepared.finish(error)
            throw error
        }
        try await prepared.finish()
    }
}
