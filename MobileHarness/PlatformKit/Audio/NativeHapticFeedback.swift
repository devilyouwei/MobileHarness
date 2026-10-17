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
        private let admission: PlatformAdmission?
        private var operation: Task<Void, any Error>?
        public init(admission: PlatformAdmission? = nil) { self.admission = admission }
        public func stop() async {
            let operation = operation
            operation?.cancel()
            _ = await operation?.result
        }
        public func prepare(_ style: Style = .heavy) {
            guard admission?.isOpen != false else { return }
            guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
            generator(style).prepare()
        }
        public func impact(style: Style, intensity: Double, count: Int, intervalMS: Int) async throws {
            try admission?.check()
            guard operation == nil else { throw Failure.busy }
            let task = Task {
                try await self.perform(style: style, intensity: intensity, count: count, intervalMS: intervalMS)
            }
            operation = task
            defer { operation = nil }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
        private func perform(style: Style, intensity: Double, count: Int, intervalMS: Int) async throws {
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
                try admission?.check()
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
