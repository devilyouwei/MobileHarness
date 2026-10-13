import Foundation
import FunctionContracts

extension UIActions {
    public enum NoticeTone: String, Sendable, CaseIterable { case info, warning, error }
    public enum EffectError: Error { case unavailable, busy }
    public struct NoticeRequest: Sendable, Equatable {
        public let text: String
        public let tone: NoticeTone
        public let durationMS: Int
        public init(text: String, tone: NoticeTone = .warning, durationMS: Int = 8000) throws {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                text.utf8.count <= 1024, (500...30000).contains(durationMS)
            else { throw PresentationError.invalidCall }
            self.text = text
            self.tone = tone
            self.durationMS = durationMS
        }
    }
    public struct LightRequest: Sendable, Equatable {
        public let enabled: Bool
        public let x: Double
        public let y: Double
        public let initialOpacity: Double
        public let intensity: Double
        public let durationMS: Int
        public init(
            enabled: Bool, x: Double = 0.5, y: Double = 0.4,
            initialOpacity: Double = 0.85, intensity: Double = 1, durationMS: Int = 3000
        ) throws {
            guard [x, y, initialOpacity, intensity].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                (500...30000).contains(durationMS)
            else { throw PresentationError.invalidCall }
            self.enabled = enabled
            self.x = x
            self.y = y
            self.initialOpacity = initialOpacity
            self.intensity = intensity
            self.durationMS = durationMS
        }
    }
}

public protocol UIEffectCapability: Sendable {
    func showNotice(_ request: UIActions.NoticeRequest, invocation: any FunctionInput) async throws
    func dismissNotice(invocation: any FunctionInput) async throws
    func updateLight(_ request: UIActions.LightRequest, invocation: any FunctionInput) async throws
}
