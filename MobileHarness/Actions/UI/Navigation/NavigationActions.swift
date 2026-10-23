import FunctionContracts

extension UIActions {
    @Action(
        domain: "UI", module: "Navigation", title: "open",
        doc:
            "On a conversational request, open the requested application page through authorized UI presentation. Touch navigation is local and does not call this Agent.",
        parameters: [
            .init(
                "destination", type: .string, required: true, description: "Existing application destination.",
                constraints: "home, settings, language, recognition, synthesis, vision, bluetooth or history.")
        ], timeout: .seconds(5))
    public static func open(invocation: any FunctionInput, using presentation: any ResourcePresentationCapability)
        async throws -> String
    {
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys(["destination"])
        let destination = try args.requiredString("destination", maximumUTF8Bytes: 32)
        guard
            ["home", "settings", "language", "recognition", "synthesis", "vision", "bluetooth", "history"].contains(
                destination)
        else { throw ResourcePresentationError.invalidGeneration }
        try Task.checkCancellation()
        try await presentation.navigate(destination, invocation: invocation)
        return "presented"
    }
}
