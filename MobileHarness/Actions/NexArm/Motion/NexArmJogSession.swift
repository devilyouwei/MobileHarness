import Foundation
import FunctionContracts

/// One manual intent state. Only admitted proposals advance the planner.
struct NexArmJogSession {
    var inputs = Array(repeating: 0.0, count: 6)
    var planner: NexArmJogPlanner?
    var hasInput: Bool { inputs.contains { abs($0) > 0.04 } }
    mutating func stop() { inputs = Array(repeating: 0, count: 6) }
    mutating func seed(_ positions: [Int]) throws { planner = try NexArmJogPlanner(positions: positions) }
}
