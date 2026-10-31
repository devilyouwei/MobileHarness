import Foundation
import Synchronization

#if os(iOS)
    import AVFAudio
#endif

final class NativeAudioInterruption: Sendable {
    private struct State: Sendable {
        var generation: UUID?
        var interrupted: Bool?
    }
    private let state = Mutex(State())
    func begin() -> UUID {
        state.withLock {
            let generation = UUID()
            $0 = State(generation: generation)
            return generation
        }
    }
    func accept(_ interrupted: Bool?, generation: UUID) {
        state.withLock { if $0.generation == generation { $0.interrupted = interrupted } }
    }
    func end() { state.withLock { $0 = State() } }
    func snapshot() -> Bool? { state.withLock { $0.interrupted } }
}

/// Observes the application's session without activating it or changing capture/playback ownership.
@MainActor final class NativeAudioState {
    private let interruption = NativeAudioInterruption()
    private var observers: [NSObjectProtocol] = []
    func start() {
        #if os(iOS)
            guard observers.isEmpty else { return }
            let generation = interruption.begin()
            let interruption = interruption
            observers = [
                NotificationCenter.default.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
                ) { notification in
                    guard let raw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
                        let kind = AVAudioSession.InterruptionType(rawValue: raw)
                    else { return }
                    interruption.accept(kind == .began, generation: generation)
                },
                NotificationCenter.default.addObserver(
                    forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
                ) { _ in interruption.accept(nil, generation: generation) },
                NotificationCenter.default.addObserver(
                    forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: nil
                ) { _ in interruption.accept(nil, generation: generation) },
            ]
        #endif
    }
    func stop() {
        interruption.end()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
    func snapshot() throws -> Data {
        #if os(iOS)
            let route = AVAudioSession.sharedInstance().currentRoute
            return try NativeSystemState.encode([
                "inputs": Array(Set(route.inputs.map { $0.portType.rawValue })).sorted(),
                "outputs": Array(Set(route.outputs.map { $0.portType.rawValue })).sorted(),
                "inputMuted": AVAudioApplication.shared.isInputMuted,
                "interrupted": interruption.snapshot() as Any? ?? NSNull(),
            ])
        #else
            return try NativeSystemState.encode([
                "inputs": [String](), "outputs": [String](), "inputMuted": NSNull(), "interrupted": NSNull(),
            ])
        #endif
    }
    static var microphoneAuthorization: String {
        #if os(iOS)
            switch AVAudioApplication.shared.recordPermission {
            case .undetermined: "notDetermined"
            case .denied: "denied"
            case .granted: "authorized"
            @unknown default: "unknown"
            }
        #else
            "unsupported"
        #endif
    }
}
