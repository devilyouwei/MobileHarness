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
    public enum EchoCancellation: String, Sendable { case unknown, unavailable, systemInput, voiceProcessing }
    public let echoCancellation: EchoCancellation
    public enum Input: Sendable { case builtInMicrophone, headset, external, unknown }
    public enum SpatialSupport: Sendable { case unknown, supported, unsupported, inputUnavailable }
    public enum Fallback: Sendable { case inputUnavailable, unsupported, startupFailed }
    public let supportsFullDuplex: Bool
    public let input: Input
    public let spatialSupport: SpatialSupport
    public let fallback: Fallback?
    public init(
        input: Input = .unknown, spatialSupport: SpatialSupport = .unknown, fallback: Fallback? = nil,
        supportsFullDuplex: Bool = false, echoCancellation: EchoCancellation = .unknown
    ) {
        self.echoCancellation = echoCancellation
        self.supportsFullDuplex = supportsFullDuplex
        self.input = input
        self.spatialSupport = spatialSupport
        self.fallback = fallback
    }
}

/// Native configuration attempts are ordered; only an observed enabled result admits duplex.
enum AudioEchoCancellationSelection {
    static func select(
        systemInput: () throws -> Bool, voiceProcessing: () throws -> Bool,
        report: (any Error) -> Void
    ) -> AudioCaptureContext.EchoCancellation {
        do { if try systemInput() { return .systemInput } } catch { report(error) }
        do { if try voiceProcessing() { return .voiceProcessing } } catch { report(error) }
        return .unavailable
    }
}
