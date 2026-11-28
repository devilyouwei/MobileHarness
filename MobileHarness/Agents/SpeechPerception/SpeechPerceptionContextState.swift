import AgentCore
import Foundation
import StorageCore

public struct SpeechPerceptionContextState: AgentContextState {
    public var phase = "listening"
    public var utteranceCount: UInt64 = 0
    public init() {}
    public func validateContextState() throws {
        guard SpeechPhase(rawValue: phase) != nil else { throw CommunicationError.invalidPayload }
    }
    public mutating func recoverInterruptedWork() {
        phase = "listening"
    }
}
