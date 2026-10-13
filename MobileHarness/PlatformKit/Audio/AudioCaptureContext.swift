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
