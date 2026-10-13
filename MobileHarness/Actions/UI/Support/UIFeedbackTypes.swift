import Foundation
import FunctionContracts

extension UIActions {
    public enum Cue: String, CaseIterable, Sendable { case wake, confirm, cancel, error, soft, save, discard }
    public enum HapticStyle: String, CaseIterable, Sendable { case light, medium, heavy, rigid, soft }
    public enum FeedbackError: Error, Sendable { case unavailable }
    public struct CueRequest: Sendable, Equatable {
        public let cue: Cue
        public let volume: Double
        public init(cue: Cue = .wake, volume: Double = 0.85) throws {
            guard volume.isFinite, (0...1).contains(volume) else {
                throw ActionArguments.ValidationError.invalidValue("volume")
            }
            self.cue = cue
            self.volume = volume
        }
    }
    public struct HapticRequest: Sendable, Equatable {
        public let style: HapticStyle
        public let intensity: Double
        public let count: Int
        public let intervalMS: Int
        public init(style: HapticStyle = .heavy, intensity: Double = 1, count: Int = 1, intervalMS: Int = 80) throws {
            guard intensity.isFinite, (0...1).contains(intensity), (1...3).contains(count),
                (40...250).contains(intervalMS)
            else { throw ActionArguments.ValidationError.invalidValue("haptic") }
            self.style = style
            self.intensity = intensity
            self.count = count
            self.intervalMS = intervalMS
        }
    }
}

public protocol UIFeedbackCapability: Sendable {
    func playCue(_ request: UIActions.CueRequest, invocation: any FunctionInput) async throws
    func vibrate(_ request: UIActions.HapticRequest, invocation: any FunctionInput) async throws
}
