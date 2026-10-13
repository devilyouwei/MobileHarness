#if os(iOS)
    import CoreHaptics
    import Foundation
    import UIKit

    /// Generic native impact requests, independent of application policy and presentation state.
    @MainActor public final class NativeHapticFeedback {
        public enum Style: String, CaseIterable, Sendable { case light, medium, heavy, rigid, soft }
        public enum Failure: Error, Sendable { case unavailable, busy, invalidRequest }
        private var generators: [Style: UIImpactFeedbackGenerator] = [:]
        private var busy = false
        public init() {}
        public func prepare(_ style: Style = .heavy) {
            guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
            generator(style).prepare()
        }
        public func impact(style: Style, intensity: Double, count: Int, intervalMS: Int) async throws {
            try Task.checkCancellation()
            guard intensity.isFinite, (0...1).contains(intensity), (1...3).contains(count),
                (40...250).contains(intervalMS)
            else { throw Failure.invalidRequest }
            guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { throw Failure.unavailable }
            guard !busy else { throw Failure.busy }
            busy = true
            defer { busy = false }
            let native = generator(style)
            native.prepare()
            for pulse in 0..<count {
                if pulse > 0 { try await Task.sleep(for: .milliseconds(intervalMS)) }
                try Task.checkCancellation()
                native.impactOccurred(intensity: CGFloat(intensity))
            }
            try Task.checkCancellation()
        }
        private func generator(_ style: Style) -> UIImpactFeedbackGenerator {
            if let existing = generators[style] { return existing }
            let nativeStyle: UIImpactFeedbackGenerator.FeedbackStyle
            switch style {
            case .light: nativeStyle = .light
            case .medium: nativeStyle = .medium
            case .heavy: nativeStyle = .heavy
            case .rigid: nativeStyle = .rigid
            case .soft: nativeStyle = .soft
            }
            let value = UIImpactFeedbackGenerator(style: nativeStyle)
            generators[style] = value
            return value
        }
    }
#endif
