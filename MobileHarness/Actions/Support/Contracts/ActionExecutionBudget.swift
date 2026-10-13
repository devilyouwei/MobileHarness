import Foundation

/// Estimates are metadata; only the upper bound cancels execution, never a minimum wait.
public struct ActionExecutionBudget: Sendable, Equatable {
    /// Shared intrinsic fallback, including anonymous composition leaves.
    public static let defaultTimeout: Duration = .seconds(30)
    public static let `default` = Self(expected: .zero, validatedTimeout: defaultTimeout)
    private init(expected: Duration, validatedTimeout: Duration) {
        self.expected = expected
        self.timeout = validatedTimeout
    }
    public let expected: Duration
    public let timeout: Duration
    public enum InvalidBudget: Error { case outOfRange }
    public init(expected: Duration, timeout: Duration) throws {
        guard expected >= .zero, timeout > .zero, timeout >= expected, timeout <= .seconds(86_400) else {
            throw InvalidBudget.outOfRange
        }
        self.expected = expected
        self.timeout = timeout
    }
    public static func sequence(_ values: [Self]) throws -> Self {
        guard !values.isEmpty else { return try Self(expected: .zero, timeout: .milliseconds(100)) }
        return try Self(
            expected: values.reduce(.zero) { $0 + $1.expected }, timeout: values.reduce(.zero) { $0 + $1.timeout })
    }
    public static func parallel(_ values: [Self]) throws -> Self {
        guard !values.isEmpty else { return try Self(expected: .zero, timeout: .milliseconds(100)) }
        return try Self(expected: values.map(\.expected).max() ?? .zero, timeout: values.map(\.timeout).max() ?? .zero)
    }
}
