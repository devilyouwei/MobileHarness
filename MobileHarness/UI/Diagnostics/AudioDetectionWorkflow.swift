import Foundation
import Observation

/// Display-only values; the App maps native capture facts and Agent observations here.
public struct AudioDetectionSnapshot: Sendable, Equatable {
    public enum Input: Sendable { case unknown, builtInMicrophone, headset, external }
    public enum Support: Sendable { case unknown, supported, unsupported, inputUnavailable }
    public enum Capture: Sendable { case waiting, spatial, mono }
    public enum Fallback: Sendable { case inputUnavailable, unsupported, startupFailed }
    public enum Signal: Sendable { case waiting, receiving, noAudio }
    public enum Direction: Sendable { case waiting, active, inactive, uncertain, unavailable }
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
    @ObservationIgnored var presentationAdmission: UIPresentationAdmission?
    public var isPresentationAvailable: Bool { presentationAdmission.map { $0.started && !$0.stopped } ?? true }

    public enum Phase { case idle, preparing, running, stopping, finished, stopped, failed }
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
        @Bindable var state: AudioDetectionState
        let requests: UIRequests<AudioDetectionInput, Void>
        @Environment(\.scenePhase) private var scenePhase
        var body: some View {
            Section {
                Button(state.isActive ? "停止检测" : "开始检测") {
                    submit(state.isActive ? .stop : .start)
                }
                .disabled(state.phase == .stopping)
                .accessibilityIdentifier("settings.recognition.detect")
                if state.phase != .idle {
                    LabeledContent("采集方式", value: capture)
                        .accessibilityIdentifier("settings.recognition.capture")
                    if let fallback = state.snapshot.fallback {
                        Text(reason(fallback)).font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("麦克风", value: input)
                    LabeledContent("空间采集", value: support)
                    HStack {
                        Text(signal)
                        Spacer()
                        ProgressView(value: state.snapshot.level)
                            .frame(width: 90)
                            .accessibilityLabel("声音强度")
                    }
                    LabeledContent("声源方向", value: direction)
                        .accessibilityIdentifier("settings.recognition.direction")
                    if let error = state.error { Text(error).font(.caption).foregroundStyle(.red) }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("音频检测")
            } footer: {
                Text("检测 10 秒。方向使用采集坐标，未校准。")
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
            case .waiting: "等待音频"
            case .spatial: "空间采集 · 4 声道"
            case .mono: "普通录音 · 单声道"
            }
        }
        private var input: String {
            if state.snapshot.permissionGranted == false { return "未授权" }
            switch state.snapshot.input {
            case .unknown: return "等待检测"
            case .builtInMicrophone: return "内置麦克风"
            case .headset: return "耳机"
            case .external: return "外接麦克风"
            }
        }
        private var support: String {
            switch state.snapshot.support {
            case .unknown: "尚未确认"
            case .supported: "支持"
            case .unsupported: "不支持"
            case .inputUnavailable: "当前输入不支持"
            }
        }
        private var signal: String {
            switch state.snapshot.signal {
            case .waiting: "等待音频"
            case .receiving: "音频正常"
            case .noAudio: "无音频"
            }
        }
        private var direction: String {
            if !state.isActive && state.snapshot.direction != .unavailable { return "检测已结束" }
            switch state.snapshot.direction {
            case .active:
                if let azimuth = state.snapshot.azimuthDegrees, let elevation = state.snapshot.elevationDegrees {
                    return String(format: "方位 %+.0f° · 俯仰 %+.0f°", azimuth, elevation)
                }
                return "等待更新"
            case .waiting: return "等待更新"
            case .inactive: return "安静"
            case .uncertain: return "方向不确定"
            case .unavailable: return "方向不可用"
            }
        }
        private func reason(_ fallback: AudioDetectionSnapshot.Fallback) -> String {
            switch fallback {
            case .inputUnavailable: "当前麦克风不支持空间采集，使用普通录音。"
            case .unsupported: "设备不支持空间采集，使用普通录音。"
            case .startupFailed: "空间采集启动失败，改用普通录音。"
            }
        }
        private var status: String {
            switch state.phase {
            case .idle: ""
            case .preparing: "正在准备麦克风…"
            case .running: "正在检测"
            case .stopping: "正在停止…"
            case .finished: "检测完成"
            case .stopped: "已停止"
            case .failed: "检测失败"
            }
        }
    }
#endif

public enum AudioDetectionInput: Sendable, Equatable { case start, stop }
