import Foundation

/// Feedback after a committed disposition cannot undo the saved result.
public enum PhotoDispositionWorkflow {
    @MainActor public static func feedback(_ operation: @MainActor () async throws -> Void) async -> [String] {
        do {
            try await operation()
            return []
        } catch { return ["feedback: " + String(String(describing: error).prefix(256))] }
    }
}
