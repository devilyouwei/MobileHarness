import Foundation
import FunctionContracts

/// Native commit and optional feedback have different failure semantics.
public enum PhotoDispositionWorkflow {
    @MainActor public static func run(
        commit: @escaping @MainActor @Sendable () async throws -> Void,
        animation: @escaping @MainActor @Sendable () async throws -> Void,
        sound: @escaping @MainActor @Sendable () async throws -> Void,
        remove: @escaping @MainActor @Sendable () -> Void
    ) async throws -> [String] {
        try Task.checkCancellation()
        try await commit()
        defer { remove() }
        try Task.checkCancellation()
        async let visual = effect("animation", operation: animation)
        async let audible = effect("sound", operation: sound)
        let outcomes = try await (visual, audible)
        try Task.checkCancellation()
        return [outcomes.0, outcomes.1].compactMap { $0 }
    }
    @MainActor private static func effect(
        _ name: String, operation: @MainActor @Sendable () async throws -> Void
    ) async throws -> String? {
        do {
            try Task.checkCancellation()
            try await operation()
            try Task.checkCancellation()
            return nil
        } catch is CancellationError { throw CancellationError() } catch {
            return name + ": " + String(String(describing: error).prefix(256))
        }
    }
}
