import Foundation
import FunctionContracts

extension SystemActions {
    @Action(
        domain: "System", module: "ModelResources", title: "snapshotResources",
        doc:
            "Read current shared model resource inventory, installed groups and progress. Does not download, remove or switch a model.",
        parameters: [],
        timeout: .seconds(60))
    public static func snapshotResources(
        invocation: any FunctionInput, using inventory: any ModelResourceInventoryCapability
    ) async throws -> String {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        return try await ModelResourceInventory.read(using: inventory).encoded()
    }

    @Action(
        domain: "System", module: "ModelResources", title: "restoreSource",
        timeout: .seconds(60))
    public static func restoreSource(
        invocation: any FunctionInput, using preferences: any ModelResourcePreferencesCapability
    ) async throws -> String {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try Task.checkCancellation()
        return try await preferences.restoreSource().encoded()
    }
    @Action(
        domain: "System", module: "ModelResources", title: "saveSource",
        timeout: .seconds(60))
    public static func saveSource(
        invocation: any FunctionInput, using preferences: any ModelResourcePreferencesCapability
    ) async throws -> String {
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys(["endpoint", "allowsCellular", "recognition", "synthesis", "decision"])
        let decision = invocation.call.parameters["decision"] ?? "false"
        guard ["true", "false"].contains(decision) else {
            throw ActionArguments.ValidationError.invalidValue("decision")
        }
        let endpoint = try args.requiredString("endpoint", maximumUTF8Bytes: 1024)
        let flags = try ["allowsCellular", "recognition", "synthesis"].map {
            try args.requiredString($0, maximumUTF8Bytes: 5)
        }
        guard flags.allSatisfy({ ["true", "false"].contains($0) }) else {
            throw ActionArguments.ValidationError.invalidValue("preference")
        }
        try Task.checkCancellation()
        return try await preferences.saveSource(
            .init(
                endpoint: endpoint, allowsCellular: flags[0] == "true",
                useCustomRecognition: flags[1] == "true", useCustomSynthesis: flags[2] == "true",
                useLocalDecision: decision == "true")
        ).encoded()
    }

    @Action(
        domain: "System", module: "ModelResources", title: "configureSpeech",
        timeout: .seconds(60))
    public static func configureSpeech(invocation: any FunctionInput, using resources: any ModelResourceCapability)
        async throws
    {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["recognition", "synthesis"])
        let recognition = try arguments.requiredString("recognition", maximumUTF8Bytes: 5)
        let synthesis = try arguments.requiredString("synthesis", maximumUTF8Bytes: 5)
        guard ["true", "false"].contains(recognition), ["true", "false"].contains(synthesis) else {
            throw ActionArguments.ValidationError.invalidValue("speechPreference")
        }
        try await resources.configureSpeech(recognition: recognition == "true", synthesis: synthesis == "true")
        try Task.checkCancellation()
    }

    @Action(
        domain: "System", module: "ModelResources", title: "download",
        doc:
            "Admit a model download using an explicit source. Admission does not mean installed; read the shared inventory for progress.",
        parameters: [
            .init("id", type: .string, required: true, description: "id", constraints: ""),
            .init("endpoint", type: .string, required: true, description: "endpoint", constraints: ""),
            .init(
                "allowsCellular", type: .string, required: true, description: "allowsCellular",
                constraints: "One of: true, false", values: ["true", "false"]),
        ],
        timeout: .seconds(60))
    public static func download(invocation: any FunctionInput, using resources: any ModelResourceCapability)
        async throws
    {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["id", "endpoint", "allowsCellular"])
        let id = try arguments.requiredString("id", maximumUTF8Bytes: 64)
        let endpoint = try arguments.requiredString("endpoint", maximumUTF8Bytes: 1024)
        let cellular = try arguments.requiredString("allowsCellular", maximumUTF8Bytes: 5)
        guard !id.isEmpty, ["true", "false"].contains(cellular) else {
            throw ActionArguments.ValidationError.invalidValue("allowsCellular")
        }
        try await resources.download(id, endpoint: endpoint, allowsCellular: cellular == "true")
        try Task.checkCancellation()
    }

    @Action(
        domain: "System", module: "ModelResources", title: "cancel",
        doc: "Cancel and join an admitted model transfer. Failure is returned without replay.",
        parameters: [.init("id", type: .string, required: true, description: "id", constraints: "")],
        timeout: .seconds(60))
    public static func cancel(invocation: any FunctionInput, using resources: any ModelResourceCapability) async throws
    {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["id"])
        let id = try arguments.requiredString("id", maximumUTF8Bytes: 64)
        try await resources.cancel(id)
        try Task.checkCancellation()
    }

    @Action(
        domain: "System", module: "ModelResources", title: "remove",
        timeout: .seconds(60))
    public static func remove(invocation: any FunctionInput, using resources: any ModelResourceCapability) async throws
    {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["id"])
        let id = try arguments.requiredString("id", maximumUTF8Bytes: 64)
        try await resources.remove(id)
        try Task.checkCancellation()
    }
}
