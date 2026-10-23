import FunctionContracts

public protocol AudioDetectionCapability: Sendable {
    func runDetection(invocation: any FunctionInput) async throws
}
