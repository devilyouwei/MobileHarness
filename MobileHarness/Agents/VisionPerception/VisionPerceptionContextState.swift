import AgentCore
import Foundation
import ModelKit
import PlatformKit
import StorageCore

public struct VisionPerceptionContextState: AgentContextState {
    public var latestFrameSequence: UInt64?
    public var perceptionSessionID: String?
    public init() {}
    public mutating func recoverInterruptedWork() {
        perceptionSessionID = nil
    }
}
