import Foundation
import FunctionContracts
import PlatformKit
import UI

public typealias AudioDetectionObservation = DetectionObservation<
    MicrophoneChannelLayout, AudioDetectionSnapshot.Direction
>
public typealias AudioDetectionConnections = DetectionConnections<any AudioCaptureObserving, AudioDetectionObservation>
