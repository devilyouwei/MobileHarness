import Foundation
import FunctionContracts

public protocol ResourcePresentationCapability: Sendable {
    func navigate(_ destination: String, invocation: any FunctionInput) async throws
    func presentProviderResult(requestID: String, failureCode: String?, invocation: any FunctionInput) async throws
    func presentResources(_ inventory: ModelResourceInventory, generation: UInt64, invocation: any FunctionInput)
        async throws
    func presentResourcePreferenceFailure(
        _ reason: ResourcePreferenceFailureReason, message: String, invocation: any FunctionInput) async throws
    func presentResourceOperationFailure(_ message: String, invocation: any FunctionInput) async throws
    func presentResourceFailure(_ message: String, generation: UInt64, invocation: any FunctionInput) async throws
}

extension ResourcePresentationCapability {
    public func navigate(_ destination: String, invocation: any FunctionInput) async throws {
        throw ResourcePresentationError.unavailable
    }
    public func presentProviderResult(requestID: String, failureCode: String?, invocation: any FunctionInput)
        async throws
    {
        throw ResourcePresentationError.unavailable
    }
}
