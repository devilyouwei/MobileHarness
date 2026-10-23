import Foundation

/// Latest target and admitted command state for one tracking lifetime; contains no device/task owner.
struct NexArmTrackingSession {
    struct Goal: Equatable, Sendable {
        var base: Int
        var pitch: Int
    }
    var goal: Goal?
    var command = NexArmAimCommand()
    var isFollowing = false
    mutating func clear() {
        goal = nil
        if !isFollowing { command.reset() }
    }
}
