import Foundation
import FunctionContracts
import StorageCore

extension UIActions {
    @Action(
        domain: "UI", module: "ResourcePresentation", title: "showResources",
        timeout: .seconds(60))
    public static func showResources(
        invocation: any FunctionInput, inventory: any ModelResourceInventoryCapability,
        using presentation: any ResourcePresentationCapability
    ) async throws -> String {
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["generation"])
        let generation = try resourceGeneration(arguments)
        let value = try await ModelResourceInventory.read(using: inventory)
        let encoded = try value.encoded()
        try Task.checkCancellation()
        try await presentation.presentResources(value, generation: generation, invocation: invocation)
        try Task.checkCancellation()
        return encoded
    }

    @Action(domain: "UI", module: "ResourcePresentation", title: "showResourceFailure", timeout: .seconds(5))
    public static func showResourceFailure(
        invocation: any FunctionInput, using presentation: any ResourcePresentationCapability
    ) async throws -> String {
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["generation", "message"])
        let generation = try resourceGeneration(arguments)
        let message = try arguments.requiredString("message", maximumUTF8Bytes: 2048)
        try Task.checkCancellation()
        try await presentation.presentResourceFailure(message, generation: generation, invocation: invocation)
        try Task.checkCancellation()
        return "presented"
    }

    @Action(domain: "UI", module: "ResourcePresentation", title: "showResourceOperationFailure", timeout: .seconds(5))
    public static func showResourceOperationFailure(
        invocation: any FunctionInput, using presentation: any ResourcePresentationCapability
    ) async throws -> String {
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["message"])
        let message = try arguments.requiredString("message", maximumUTF8Bytes: 2048)
        try Task.checkCancellation()
        try await presentation.presentResourceOperationFailure(message, invocation: invocation)
        try Task.checkCancellation()
        return "presented"
    }

    @Action(
        domain: "UI", module: "ResourcePresentation", title: "showResourcePreferenceFailure", timeout: .seconds(5))
    public static func showResourcePreferenceFailure(
        invocation: any FunctionInput, using presentation: any ResourcePresentationCapability
    ) async throws -> String {
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["reason", "message"])
        guard
            let reason = ResourcePreferenceFailureReason(
                rawValue: try arguments.requiredString("reason", maximumUTF8Bytes: 64))
        else {
            throw ActionArguments.ValidationError.invalidValue("reason")
        }
        let message = try arguments.requiredString("message", maximumUTF8Bytes: 2048)
        try Task.checkCancellation()
        try await presentation.presentResourcePreferenceFailure(reason, message: message, invocation: invocation)
        try Task.checkCancellation()
        return "presented"
    }

    @Action(domain: "UI", module: "ResourcePresentation", title: "showProviderResult", timeout: .seconds(5))
    public static func showProviderResult(
        invocation: any FunctionInput, using presentation: any ResourcePresentationCapability
    ) async throws -> String {
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["requestID", "failureCode"])
        guard let id = UUID(uuidString: try arguments.requiredString("requestID", maximumUTF8Bytes: 36)) else {
            throw ActionArguments.ValidationError.invalidValue("requestID")
        }
        let code = invocation.call.parameters["failureCode"]
        guard code.map({ $0.utf8.count <= 64 && $0.hasPrefix("provider.") }) ?? true else {
            throw ActionArguments.ValidationError.invalidValue("failureCode")
        }
        try Task.checkCancellation()
        try await presentation.presentProviderResult(
            requestID: id.uuidString, failureCode: code, invocation: invocation)
        return "presented"
    }

    private static func resourceGeneration(_ arguments: ActionArguments) throws -> UInt64 {
        guard let value = UInt64(try arguments.requiredString("generation", maximumUTF8Bytes: 20)), value > 0 else {
            throw ResourcePresentationError.invalidGeneration
        }
        return value
    }
}
public enum ResourcePresentationError: Error, Sendable { case invalidGeneration, staleGeneration, unavailable }

public enum ResourcePreferenceFailureReason: String, Sendable {
    case invalidSource, recognitionRequired, synthesisRequired, execution
}
