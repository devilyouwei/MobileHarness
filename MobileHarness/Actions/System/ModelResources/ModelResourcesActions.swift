import Foundation
import FunctionContracts
import ModelKitDefaults

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
        doc: "Restore the persisted model download source selection into the resource settings UI.",
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
        doc: "Persist the selected model download source and its endpoint settings.",
        timeout: .seconds(60))
    public static func saveSource(
        invocation: any FunctionInput, using preferences: any ModelResourcePreferencesCapability
    ) async throws -> String {
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys([
            "endpoint", "allowsCellular", "recognition", "synthesis", "decision", "vadOnsetWindows", "vadThreshold",
            "enhancement", "keywordInterrupt", "speechModels", "synthesisVoice", "keywordThreshold",
        ])
        guard let windows = Int(invocation.call.parameters["vadOnsetWindows"] ?? "8"),
            let threshold = Double(invocation.call.parameters["vadThreshold"] ?? "0.65"),
            (1...16).contains(windows), threshold.isFinite, (0.05...0.95).contains(threshold),
            abs(threshold * 20 - (threshold * 20).rounded()) < 0.00001
        else { throw ActionArguments.ValidationError.invalidValue("speechDetection") }
        guard let keywordThreshold = Double(invocation.call.parameters["keywordThreshold"] ?? "0.25"),
            ModelResourcePreferences.isValidKeywordThreshold(keywordThreshold)
        else { throw ActionArguments.ValidationError.invalidValue("keywordThreshold") }
        let enhancement = invocation.call.parameters["enhancement"] ?? "false"
        guard ["true", "false"].contains(enhancement) else {
            throw ActionArguments.ValidationError.invalidValue("enhancement")
        }
        let keywordInterrupt = invocation.call.parameters["keywordInterrupt"] ?? "false"
        guard ["true", "false"].contains(keywordInterrupt) else {
            throw ActionArguments.ValidationError.invalidValue("keywordInterrupt")
        }
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
                useLocalDecision: decision == "true", vadOnsetWindows: windows, vadThreshold: threshold,
                useSpeechEnhancement: enhancement == "true", useKeywordInterrupt: keywordInterrupt == "true",
                speechModels: try speechModels(invocation), synthesisVoice: try synthesisVoice(invocation),
                keywordThreshold: keywordThreshold)
        ).encoded()
    }

    @Action(
        domain: "System", module: "ModelResources", title: "configureSpeech",
        doc: "Select the speech recognition and speech synthesis resources used by the app.",
        timeout: .seconds(60))
    public static func configureSpeech(invocation: any FunctionInput, using resources: any ModelResourceCapability)
        async throws
    {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["recognition", "synthesis", "speechModels", "synthesisVoice"])
        let recognition = try arguments.requiredString("recognition", maximumUTF8Bytes: 5)
        let synthesis = try arguments.requiredString("synthesis", maximumUTF8Bytes: 5)
        guard ["true", "false"].contains(recognition), ["true", "false"].contains(synthesis) else {
            throw ActionArguments.ValidationError.invalidValue("speechPreference")
        }
        let voice = try synthesisVoice(invocation)
        if let models = try speechModels(invocation) {
            try await resources.configureSpeechModels(models, synthesisVoice: voice)
        } else {
            guard voice == nil else { throw ActionArguments.ValidationError.invalidValue("synthesisVoice") }
            try await resources.configureSpeech(recognition: recognition == "true", synthesis: synthesis == "true")
        }
        try Task.checkCancellation()
    }

    private static func synthesisVoice(_ invocation: any FunctionInput) throws -> String? {
        guard invocation.call.parameters["synthesisVoice"] != nil else { return nil }
        return try ActionArguments(invocation.call.parameters).requiredString("synthesisVoice", maximumUTF8Bytes: 64)
    }

    private static func speechModels(_ invocation: any FunctionInput) throws -> [String: String]? {
        guard let raw = invocation.call.parameters["speechModels"] else { return nil }
        let capabilityCount = Set(SpeechModelOption.catalog.map(\.capability)).count
        guard raw.utf8.count <= 1024,
            let models = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)),
            models.count <= capabilityCount,
            models.allSatisfy({ $0.key.utf8.count <= 32 && $0.value.utf8.count <= 64 })
        else { throw ActionArguments.ValidationError.invalidValue("speechModels") }
        return models
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
        doc: "Remove a downloaded model resource by its resource id.",
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
