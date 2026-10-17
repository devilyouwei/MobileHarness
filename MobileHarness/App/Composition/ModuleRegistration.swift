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
                id: "platform", start: { try services.platform.start() },
                invalidate: services.platform.invalidate,
                foreground: { try await services.platform.setForeground($0) },
                stop: { try await services.platform.stop() }),
            ManagedService(
                id: "ui", start: { try services.uiContainer.start() },
                invalidate: services.uiContainer.invalidate,
                foreground: { try services.uiContainer.setForeground($0) },
                stop: { await services.uiContainer.stop() }),
            ManagedService(
                id: "agents", dependencies: ["storage", "platform", "ui"],
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
