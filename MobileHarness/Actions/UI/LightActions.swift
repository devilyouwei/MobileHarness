import FunctionContracts

extension UIActions {
    @Action(
        domain: "UI", module: "Light", title: "更新装饰光效",
        doc:
            "Commit a temporary decorative halo. Enabled replays expansion from normalized origin; disabled clears this producer/session override and restores listening light. Never changes microphone, eyes or listening consent. Root owns expiry.",
        parameters: [
            .init("enabled", type: .boolean, required: true, description: "Show temporary halo or clear own override."),
            .init(
                "x", type: .number, required: false, description: "Normalized horizontal origin, default 0.5.",
                constraints: "Finite 0 through 1."),
            .init(
                "y", type: .number, required: false, description: "Normalized vertical origin, default 0.4.",
                constraints: "Finite 0 through 1."),
            .init(
                "initialOpacity", type: .number, required: false, description: "Initial source opacity, default 0.85.",
                constraints: "Finite 0 through 1."),
            .init(
                "intensity", type: .number, required: false, description: "Relative brightness, default 1.",
                constraints: "Finite 0 through 1."),
            .init(
                "durationMS", type: .integer, required: false, description: "Auto-clear delay, default 3000.",
                constraints: "500 through 30000 milliseconds."),
        ], completion: "Light state committed; renderer owns frame presentation.", timeout: .seconds(5))
    public static func updateLight(
        invocation: any FunctionInput,
        using present: @escaping @Sendable (LightRequest, any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys(["enabled", "x", "y", "initialOpacity", "intensity", "durationMS"])
        let rawEnabled = try args.requiredString("enabled", maximumUTF8Bytes: 5)
        guard let enabled = Bool(rawEnabled) else { throw ActionArguments.ValidationError.invalidValue("enabled") }
        let request = try LightRequest(
            enabled: enabled,
            x: invocation.call.parameters["x"] == nil ? 0.5 : args.requiredFiniteDouble("x", range: 0...1),
            y: invocation.call.parameters["y"] == nil ? 0.4 : args.requiredFiniteDouble("y", range: 0...1),
            initialOpacity: invocation.call.parameters["initialOpacity"] == nil
                ? 0.85 : args.requiredFiniteDouble("initialOpacity", range: 0...1),
            intensity: invocation.call.parameters["intensity"] == nil
                ? 1 : args.requiredFiniteDouble("intensity", range: 0...1),
            durationMS: invocation.call.parameters["durationMS"] == nil
                ? 3000 : args.requiredInt("durationMS", range: 500...30000))
        try await present(request, invocation)
    }
}
