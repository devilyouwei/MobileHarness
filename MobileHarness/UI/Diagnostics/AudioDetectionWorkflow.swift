import Foundation
import Observation

/// Display-only values; the App maps native capture facts and Agent observations here.
public struct AudioDetectionSnapshot: Sendable, Equatable {
    public enum Input: String, CaseIterable, Sendable { case unknown, builtInMicrophone, headset, external }
    public enum Support: String, CaseIterable, Sendable { case unknown, supported, unsupported, inputUnavailable }
    public enum Capture: String, CaseIterable, Sendable { case waiting, spatial, mono }
    public enum Fallback: String, CaseIterable, Sendable { case inputUnavailable, unsupported, startupFailed }
    public enum Signal: String, CaseIterable, Sendable { case waiting, receiving, noAudio }
    public enum Direction: String, CaseIterable, Sendable { case waiting, active, inactive, uncertain, unavailable }
    public var permissionGranted: Bool?
    public var input: Input = .unknown
    public var support: Support = .unknown
    public var capture: Capture = .waiting
    public var fallback: Fallback?
    public var sampleRate = 0
    public var signal: Signal = .waiting
    public var level = 0.0
    public var direction: Direction = .waiting
    public var azimuthDegrees: Double?
    public var elevationDegrees: Double?
    public var capturedAt: ContinuousClock.Instant?
    public var directionExpiresAt: ContinuousClock.Instant?
    public init() {}
}

@MainActor
@Observable
public final class AudioDetectionState {
    public func stateSnapshot() async throws -> UIStateSnapshot {
        try Task.checkCancellation()
        let observation = snapshot
        let now = ContinuousClock.now
        let age = observation.capturedAt.map { $0.duration(to: now) }
        let seconds = age.map { max(0, Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) }
        let directionFresh: UIStateSnapshot.Value =
            observation.direction == .active
            ? observation.directionExpiresAt.map { .flag(now < $0) } ?? .unknown : .flag(false)
        return .init(
            path: "ui.diagnostics.audio",
            business: [
                "input": .text(observation.input.rawValue), "signal": .text(observation.signal.rawValue),
                "direction": .text(observation.direction.rawValue), "level": .number(observation.level),
                "azimuthDegrees": observation.azimuthDegrees.map { .number($0) } ?? .unknown,
                "elevationDegrees": observation.elevationDegrees.map { .number($0) } ?? .unknown,
                "permissionGranted": observation.permissionGranted.map { .flag($0) } ?? .unknown,
                "sampleAgeSeconds": seconds.map { .number($0) } ?? .unknown,
                "signalFresh": seconds.map { .flag($0 <= 1) } ?? .unknown,
                "directionFresh": directionFresh,
            ],
            runtime: [
                "phase": .text(phase.rawValue), "support": .text(observation.support.rawValue),
                "capture": .text(observation.capture.rawValue), "sampleRate": .count(observation.sampleRate),
                "fallback": observation.fallback.map { .text($0.rawValue) } ?? .unknown,
                "available": .flag(isPresentationAvailable),
            ],
            meanings: [
                "business.direction":
                    "Retained direction observation; directionFresh determines whether the angle evidence is current",
                "business.level":
                    "Displayed level; signalFresh distinguishes recent sample evidence from retained display values",
                "business.signalFresh":
                    "A sample receipt exists with age at most one second; unknown before receipt",
                "business.directionFresh":
                    "Active direction has a future expiry deadline; unknown without that deadline",
                "runtime.phase": "Diagnostic workflow phase, not a user listening/speaking phase",
            ],
            units: [
                "business.azimuthDegrees": "degrees", "business.elevationDegrees": "degrees",
                "runtime.sampleRate": "Hz", "business.sampleAgeSeconds": "seconds",
            ],
            stateValues: [
                "business.input": AudioDetectionSnapshot.Input.allCases.map(\.rawValue),
                "business.signal": AudioDetectionSnapshot.Signal.allCases.map(\.rawValue),
                "business.direction": AudioDetectionSnapshot.Direction.allCases.map(\.rawValue),
                "runtime.phase": AudioDetectionState.Phase.allCases.map(\.rawValue),
                "runtime.support": AudioDetectionSnapshot.Support.allCases.map(\.rawValue),
                "runtime.capture": AudioDetectionSnapshot.Capture.allCases.map(\.rawValue),
                "runtime.fallback": AudioDetectionSnapshot.Fallback.allCases.map(\.rawValue),
            ])
    }

    @ObservationIgnored var presentationAdmission: UIPresentationAdmission?
    public var isPresentationAvailable: Bool { presentationAdmission.map { $0.started && !$0.stopped } ?? true }

    public enum Phase: String, CaseIterable, Sendable {
        case idle, preparing, running, stopping, finished, stopped, failed
    }
    public internal(set) var phase: Phase = .idle
    public internal(set) var snapshot = AudioDetectionSnapshot()
    public internal(set) var error: String?
    public var isActive: Bool { phase == .preparing || phase == .running || phase == .stopping }
    public init() {}
    public func refresh(at now: ContinuousClock.Instant = .now) {
        guard presentationAdmission?.acceptsRetained() ?? true else { return }
        if let capturedAt = snapshot.capturedAt, capturedAt.duration(to: now) > .seconds(1) {
            snapshot.signal = .noAudio
            snapshot.level = 0
        }
        if let deadline = snapshot.directionExpiresAt, deadline <= now {
            if snapshot.direction == .active { clearDirection() } else { snapshot.directionExpiresAt = nil }
        }
    }
    public func clearDirection() {
        guard presentationAdmission?.acceptsRetained() ?? true else { return }
        if snapshot.direction != .unavailable { snapshot.direction = .waiting }
        snapshot.azimuthDegrees = nil
        snapshot.elevationDegrees = nil
        snapshot.directionExpiresAt = nil
    }

    @discardableResult
    public func present(_ update: AudioDetectionUpdate) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        apply(update)
        return true
    }
    func apply(_ update: AudioDetectionUpdate) {
        switch update {
        case .level(let value): snapshot.level = value
        case .phase(let value): phase = value
        case .snapshot(let value): snapshot = value
        case .error(let value): error = value
        }
    }
}

/// Whole diagnostic endpoint supplied by App; neither UI nor the workflow constructs an Agent/device.
@MainActor
public protocol AudioDetectionRunning: AnyObject {
    func run(update: @escaping @MainActor @Sendable (AudioDetectionSnapshot) -> Void) async throws
}

public enum AudioDetectionUpdate {
    case level(Double)
    case phase(AudioDetectionState.Phase)
    case snapshot(AudioDetectionSnapshot)
    case error(String?)
}

@MainActor
public protocol AudioDetectionPresenting: UIPresentationAccess {
    var phase: AudioDetectionState.Phase { get }
    var snapshot: AudioDetectionSnapshot { get }
    var error: String? { get }
    var isActive: Bool { get }
    @discardableResult
    func present(_ update: AudioDetectionUpdate) -> Bool
    func refresh(at now: ContinuousClock.Instant)
    func clearDirection()
}

extension AudioDetectionState: AudioDetectionPresenting {}

extension AudioDetectionPresenting {
    public func refresh() { refresh(at: .now) }
}

#if os(iOS)
    import SwiftUI

    @MainActor
    struct AudioDetectionSection: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        @Bindable var state: AudioDetectionState
        let requests: UIRequests<AudioDetectionInput, Void>
        @Environment(\.scenePhase) private var scenePhase
        var body: some View {
            Section {
                Button(state.isActive ? appCopy.text("Stop detection") : appCopy.text("Start detection")) {
                    submit(state.isActive ? .stop : .start)
                }
                .disabled(state.phase == .stopping)
                .accessibilityIdentifier("settings.recognition.detect")
                if state.phase != .idle {
                    LabeledContent(appCopy.text("Capture mode"), value: capture)
                        .accessibilityIdentifier("settings.recognition.capture")
                    if let fallback = state.snapshot.fallback {
                        Text(reason(fallback)).font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent(appCopy.text("Microphone"), value: input)
                    LabeledContent(appCopy.text("Spatial capture"), value: support)
                    HStack {
                        Text(signal)
                        Spacer()
                        ProgressView(value: state.snapshot.level)
                            .frame(width: 90)
                            .accessibilityLabel(appCopy.text("Sound level"))
                    }
                    LabeledContent(appCopy.text("Sound direction"), value: direction)
                        .accessibilityIdentifier("settings.recognition.direction")
                    if let error = state.error { Text(appCopy.text(error)).font(.caption).foregroundStyle(.red) }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(appCopy.text("Audio detection"))
            } footer: {
                Text(appCopy.text("Detection lasts 10 seconds. Direction uses uncalibrated capture coordinates."))
            }
            .onDisappear { submit(.stop) }
            .onChange(of: scenePhase) { _, phase in if phase != .active { submit(.stop) } }
        }
        private func submit(_ value: AudioDetectionInput) {
            Task {
                do {
                    if value == .stop {
                        try await requests.submitControl(value)
                    } else {
                        try await requests.submit(value)
                    }
                } catch { state.present(.error(error.localizedDescription)) }
            }
        }
        private var capture: String {
            switch state.snapshot.capture {
            case .waiting: appCopy.text("Waiting for audio")
            case .spatial: appCopy.text("Spatial capture · 4 channels")
            case .mono: appCopy.text("Standard recording · Mono")
            }
        }
        private var input: String {
            if state.snapshot.permissionGranted == false { return appCopy.text("Permission denied") }
            switch state.snapshot.input {
            case .unknown: return appCopy.text("Waiting for detection")
            case .builtInMicrophone: return appCopy.text("Built-in microphone")
            case .headset: return appCopy.text("Headset")
            case .external: return appCopy.text("External microphone")
            }
        }
        private var support: String {
            switch state.snapshot.support {
            case .unknown: appCopy.text("Unconfirmed")
            case .supported: appCopy.text("Supported")
            case .unsupported: appCopy.text("Unsupported")
            case .inputUnavailable: appCopy.text("Input unsupported")
            }
        }
        private var signal: String {
            switch state.snapshot.signal {
            case .waiting: appCopy.text("Waiting for audio")
            case .receiving: appCopy.text("Receiving audio")
            case .noAudio: appCopy.text("No audio")
            }
        }
        private var direction: String {
            if !state.isActive && state.snapshot.direction != .unavailable { return appCopy.text("Detection ended") }
            switch state.snapshot.direction {
            case .active:
                if let azimuth = state.snapshot.azimuthDegrees, let elevation = state.snapshot.elevationDegrees {
                    return appCopy.format("Azimuth %+.0f° · Elevation %+.0f°", azimuth, elevation)
                }
                return appCopy.text("Waiting for an update")
            case .waiting: return appCopy.text("Waiting for an update")
            case .inactive: return appCopy.text("Quiet")
            case .uncertain: return appCopy.text("Direction uncertain")
            case .unavailable: return appCopy.text("Direction unavailable")
            }
        }
        private func reason(_ fallback: AudioDetectionSnapshot.Fallback) -> String {
            switch fallback {
            case .inputUnavailable:
                appCopy.text("The microphone does not support spatial capture. Using standard recording.")
            case .unsupported: appCopy.text("The device does not support spatial capture. Using standard recording.")
            case .startupFailed: appCopy.text("Spatial capture failed to start. Using standard recording.")
            }
        }
        private var status: String {
            switch state.phase {
            case .idle: ""
            case .preparing: appCopy.text("Preparing microphone…")
            case .running: appCopy.text("Detecting")
            case .stopping: appCopy.text("Stopping…")
            case .finished: appCopy.text("Detection completed")
            case .stopped: appCopy.text("Stopped")
            case .failed: appCopy.text("Detection failed")
            }
        }
    }
#endif

public enum AudioDetectionInput: Sendable, Equatable { case start, stop }
