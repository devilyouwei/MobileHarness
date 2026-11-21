import Foundation
import FunctionContracts
import PlatformKit
import UI

public protocol AudioDetectionCapability: Sendable {
    func runDetection(invocation: any FunctionInput) async throws
}

public typealias AudioDetectionObservation = DetectionObservation<
    MicrophoneChannelLayout, AudioDetectionSnapshot.Direction
>
public typealias AudioDetectionConnections = DetectionConnections<any AudioCaptureObserving, AudioDetectionObservation>
