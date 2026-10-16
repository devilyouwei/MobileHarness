import AppLifecycle

@MainActor enum ModuleRegistration {
    static func lifecycle(_ services: ServiceFactories.Services) throws -> ApplicationLifecycle {
        try ApplicationLifecycle(services: [
            ManagedService(
                id: "storage", start: { try await services.storage.start() },
                stop: {
                    try await services.artifacts.stop()
                    try await services.storage.stop()
                }),
            ManagedService(
                id: "agents", dependencies: ["storage"],
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
