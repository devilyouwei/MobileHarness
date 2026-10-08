import FunctionContracts

extension UIActions {
    @Action(domain: "UI", module: "Navigation", title: "open", serializationKey: "UI")
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
