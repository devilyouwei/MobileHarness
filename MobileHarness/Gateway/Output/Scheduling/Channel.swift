import AgentCore
import Foundation

extension ChannelScheduler {
    /// Ownership metadata for a channel lease. This is not a device stop/hold command.
    struct ChannelLockOwner: Equatable, Sendable {
        let agentID: AgentID
        let instanceID: UUID
        let sessionID: UUID
        let leaseID: UUID
        let deadline: ContinuousClock.Instant
    }

    /// Declarative state only; runtime acquisition, enforcement and release are not implemented.
    enum ChannelLockState: Equatable, Sendable {
        case unlocked
        case locked(ChannelLockOwner)
    }

    /// FIFO state isolated by ChannelScheduler; capacity includes the running action.
    struct Channel {
        // Immutable until lock admission and execution-time enforcement are implemented together.
        let lockState: ChannelLockState = .unlocked
        var queued: [Job] = []
        var running: Running?
        var count: Int { queued.count + (running == nil ? 0 : 1) }
    }
}
