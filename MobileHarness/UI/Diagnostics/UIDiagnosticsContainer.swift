import Foundation

@MainActor
public final class UIDiagnosticsContainer {
    public func stateSnapshot() async throws -> UIStateSnapshot {
        try Task.checkCancellation()
        return UIStateSnapshot(
            path: "ui.diagnostics", runtime: ["available": .flag(speech.isPresentationAvailable)],
            children: [.init(path: "ui.diagnostics.speech"), .init(path: "ui.diagnostics.audio")])
    }
    public func stateReaders() async throws -> [String: UIStateSnapshot.Reader] {
        [
            "ui.diagnostics": UIStateSnapshot.reader(of: self) { try await $0.stateSnapshot() },
            "ui.diagnostics.speech": UIStateSnapshot.reader(of: speech) { try await $0.stateSnapshot() },
            "ui.diagnostics.audio": UIStateSnapshot.reader(of: audioDetection) { try await $0.stateSnapshot() },
        ]
    }

    public let detectionRequests = UIRequests<AudioDetectionInput, Void>()
    public let speech = SpeechDiagnosticState()
    public let audioDetection = AudioDetectionState()
    public var speechPresentation: any SpeechDiagnosticPresenting { speech }
    public var audioDetectionPresentation: any AudioDetectionPresenting { audioDetection }
    init(admission: UIPresentationAdmission) {
        speech.presentationAdmission = admission
        audioDetection.presentationAdmission = admission
    }
}
