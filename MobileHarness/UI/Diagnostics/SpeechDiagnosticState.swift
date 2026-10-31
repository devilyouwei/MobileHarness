import Foundation
import Observation

@MainActor
@Observable
public final class SpeechDiagnosticState {
    public func stateSnapshot() async throws -> UIStateSnapshot {
        try Task.checkCancellation()
        return UIStateSnapshot(
            path: "ui.diagnostics.speech",
            runtime: [
                "running": .flag(isRunning), "stopping": .flag(isStopping), "available": .flag(isPresentationAvailable),
            ])
    }

    @ObservationIgnored var presentationAdmission: UIPresentationAdmission?
    public var isPresentationAvailable: Bool { presentationAdmission.map { $0.started && !$0.stopped } ?? true }

    public internal(set) var text = "你好，Hello world，欢迎使用本地语音助手。"
    public internal(set) var report = "中英双语 · Core ML · MOSS Nano Beta · zh_1 / en_2"
    public internal(set) var isRunning = false
    public internal(set) var isStopping = false
    public init() {}
    public func presentRunning(_ value: Bool) {
        guard presentationAdmission?.acceptsRetained() ?? true else { return }
        isRunning = value
    }
    public func presentStopping(_ value: Bool) {
        guard presentationAdmission?.acceptsRetained() ?? true else { return }
        isStopping = value
    }
    public func presentReport(_ value: String) {
        guard presentationAdmission?.acceptsRetained() ?? true else { return }
        report = value
    }
    public func appendReport(_ value: String) {
        guard presentationAdmission?.acceptsRetained() ?? true else { return }
        report += value
    }

    @discardableResult
    public func present(_ update: SpeechDiagnosticUpdate) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        apply(update)
        return true
    }
    func apply(_ update: SpeechDiagnosticUpdate) {
        switch update {
        case .text(let value): text = value
        case .report(let value): report = value
        case .isRunning(let value): isRunning = value
        case .isStopping(let value): isStopping = value
        }
    }
}

@MainActor
public protocol SpeechDiagnosticControlling: AnyObject {
    func start()
    func stop()
}

public enum SpeechDiagnosticUpdate {
    case text(String)
    case report(String)
    case isRunning(Bool)
    case isStopping(Bool)
}

@MainActor
public protocol SpeechDiagnosticPresenting: UIPresentationAccess {
    var text: String { get }
    var report: String { get }
    var isRunning: Bool { get }
    var isStopping: Bool { get }
    @discardableResult
    func present(_ update: SpeechDiagnosticUpdate) -> Bool
    func presentRunning(_ value: Bool)
    func presentStopping(_ value: Bool)
    func presentReport(_ value: String)
    func appendReport(_ value: String)
}

extension SpeechDiagnosticState: SpeechDiagnosticPresenting {}
