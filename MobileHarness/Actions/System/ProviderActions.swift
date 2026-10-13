import Foundation
import FunctionContracts

extension SystemActions {
    @Action(domain: "System", module: "Provider", title: "discoverModels", timeout: .seconds(60))
    public static func discoverModels(invocation: any FunctionInput, using provider: any ProviderDiscoveryCapability)
        async throws -> String
    {
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["requestID"])
        guard let id = UUID(uuidString: try arguments.requiredString("requestID", maximumUTF8Bytes: 36)) else {
            throw ProviderDiscoveryError.invalidRequest
        }
        try Task.checkCancellation()
        let models = try await provider.discoverModels(requestID: id, sessionID: invocation.context.sessionID)
        try Task.checkCancellation()
        return try ProviderModelList.encoded(models)
    }
}

extension SystemActions {
    @Action(domain: "System", module: "Provider", title: "restoreSettings", timeout: .seconds(60))
    public static func restoreSettings(invocation: any FunctionInput, using settings: any ProviderSettingsCapability)
        async throws -> String
    {
        let id = try providerSettingsRequest(invocation)
        try Task.checkCancellation()
        try await settings.restoreSettings(requestID: id, sessionID: invocation.context.sessionID)
        return id.uuidString
    }
    @Action(domain: "System", module: "Provider", title: "saveSettings", timeout: .seconds(60))
    public static func saveSettings(invocation: any FunctionInput, using settings: any ProviderSettingsCapability)
        async throws -> String
    {
        let id = try providerSettingsRequest(invocation)
        try Task.checkCancellation()
        try await settings.saveSettings(requestID: id, sessionID: invocation.context.sessionID)
        return id.uuidString
    }
    @Action(
        domain: "System", module: "Provider", title: "readSettings",
        doc:
            "Read confirmed cloud-enabled status and selected cloud model. Contains no URL/key. Does not probe provider availability or change configuration.",
        parameters: [])
    public static func readSettings(invocation: any FunctionInput, using settings: any ProviderSettingsCapability)
        async throws -> String
    {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try Task.checkCancellation()
        return try await settings.readSettings()
    }
    private static func providerSettingsRequest(_ invocation: any FunctionInput) throws -> UUID {
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["requestID"])
        guard let id = UUID(uuidString: try arguments.requiredString("requestID", maximumUTF8Bytes: 36)) else {
            throw ProviderSettingsError.invalidConfiguration
        }
        return id
    }
}
