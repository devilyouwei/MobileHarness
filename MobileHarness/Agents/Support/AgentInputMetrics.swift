import AgentCore
import Foundation
import OSLog

/// Opt-in aggregate timings only; no media, user text, identities or additional queues.
enum ContainerInputMetrics {
    private static let enabled = ProcessInfo.processInfo.arguments.contains("-direct-input-measurements")
    private static let signposter = OSSignposter(subsystem: "dev.mobileharness", category: "ContainerInputs")
    static func rejected(_ input: AgentInput, role: String) {
        guard ProcessInfo.processInfo.arguments.contains("-direct-input-diagnostics") else { return }
        print("DIRECT_INPUT_REJECT role=\(role) source=\(input.metadata.source) contract=\(input.metadata.contract)")
    }
    static func record(_ name: StaticString, since start: ContinuousClock.Instant) {
        guard enabled else { return }
        let age = start.duration(to: .now).components
        let milliseconds = Double(age.seconds) * 1000 + Double(age.attoseconds) / 1e15
        signposter.emitEvent(name, "age_ms=\(milliseconds, privacy: .public)")
    }
}
