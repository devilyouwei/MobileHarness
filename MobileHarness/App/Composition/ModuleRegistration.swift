import AppLifecycle

@MainActor enum ModuleRegistration {
    static func lifecycle(_ services: ServiceFactories.Services) throws -> ApplicationLifecycle {
        try ApplicationLifecycle(services: [
            ManagedService(id: "repositories", start: { _ = try services.repositories.get() }, stop: {}),
            ManagedService(
                id: "agents", dependencies: ["repositories"],
                start: services.agents.startAgents,
                foreground: services.agents.setAgentForeground,
                stop: services.agents.stopAgents),
            ManagedService(
                id: "native", dependencies: ["agents"],
                start: services.agents.startNativeServices,
                invalidate: services.agents.invalidateNative,
                foreground: { services.agents.setForeground($0) },
                stop: services.agents.stopNativeServices),
        ])
    }
}
