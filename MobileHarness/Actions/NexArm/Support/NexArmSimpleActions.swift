import ActionRuntime
import Foundation
import PlatformKit

/// Single-motor definitions never prepare or reset unrelated joints.
enum NexArmSimpleActions {
    static func packet(id: Int, target: Int) throws -> NexArmPacket {
        try NexArmMotorCommands.move(motor: id, target: target, options: NexArmMotorOptions())
    }
    static func sweeps(_ gesture: NexArmGesture, home: [Int]) throws -> [NexArmGesture.TestFrame] {
        guard let id = gesture.motorID, home.count == 6 else { throw NexArmExecutionError.invalidArguments }
        let amplitude = id == 4 ? 380 : 500
        return try [-amplitude, amplitude, -amplitude, amplitude, 0].map {
            NexArmGesture.TestFrame(packet: try packet(id: id, target: home[id - 1] + $0), milliseconds: 1500)
        }
    }
    static func frames(_ gesture: NexArmGesture, home: [Int], repetitions: Int) throws -> [NexArmGesture.TestFrame] {
        guard let id = gesture.motorID, home.count == 6, (1...3).contains(repetitions) else {
            throw NexArmExecutionError.invalidArguments
        }
        let start = NexArmGesture.TestFrame(packet: try packet(id: id, target: home[id - 1]), milliseconds: 1500)
        return [start] + (try (0..<repetitions).flatMap { _ in try sweeps(gesture, home: home) })
    }
}
