import Foundation

@MainActor
public final class UIDiagnosticsContainer {
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
