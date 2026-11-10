/// Device events are facts, not automatic container execution failures.
public enum NativeAudioEvent: String, Sendable { case interrupted, routeChanged, mediaServicesReset }

struct AudioRouteIdentity: Equatable, Sendable {
    let inputs: [String]
    let outputs: [String]
    init(inputs: [String], outputs: [String]) {
        self.inputs = inputs.sorted()
        self.outputs = outputs.sorted()
    }
}

enum AudioSessionEventPolicy {
    static func routeChange(
        applicationChange: Bool, unavailable: Bool, previous: AudioRouteIdentity?, current: AudioRouteIdentity
    ) -> NativeAudioEvent? {
        if unavailable { return .routeChanged }
        guard !applicationChange else { return nil }
        guard let previous else { return .routeChanged }
        return previous == current ? nil : .routeChanged
    }
}

/// Native capture selection facts. Presentation/localization belongs to the caller.
public struct AudioCaptureContext: Sendable, Equatable {
    public enum Input: Sendable { case builtInMicrophone, headset, external, unknown }
    public enum SpatialSupport: Sendable { case unknown, supported, unsupported, inputUnavailable }
    public enum Fallback: Sendable { case inputUnavailable, unsupported, startupFailed }
    public let input: Input
    public let spatialSupport: SpatialSupport
    public let fallback: Fallback?
    public init(input: Input = .unknown, spatialSupport: SpatialSupport = .unknown, fallback: Fallback? = nil) {
        self.input = input
        self.spatialSupport = spatialSupport
        self.fallback = fallback
    }
}
