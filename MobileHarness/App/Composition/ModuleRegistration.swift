import AppLifecycle
import Gateway

private struct ServiceStopFailure: Error { let errors: [any Error] }

@MainActor enum ModuleRegistration {
    static func lifecycle(_ services: ServiceFactories.Services) throws -> ApplicationLifecycle {
        let descriptions = [
            ManagedService(
                id: "diagnostics", start: { services.containerFailures.start() },
                stop: { await services.containerFailures.stop() }),
            ManagedService(
                id: "storage", dependencies: ["diagnostics"], start: { try await services.storage.start() },
                stop: {
                    var errors: [any Error] = []
                    do { try await services.artifacts.stop() } catch { errors.append(error) }
                    do { try await services.storage.stop() } catch { errors.append(error) }
                    if !errors.isEmpty { throw ServiceStopFailure(errors: errors) }
                }),
            ManagedService(
                id: "platform", dependencies: ["diagnostics"], start: { try services.platform.start() },
                invalidate: services.platform.invalidate,
                foreground: { try await services.platform.setForeground($0) },
                stop: { try await services.platform.stop() }),
            ManagedService(
                id: "ui", dependencies: ["diagnostics"], start: { try services.uiContainer.start() },
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
        ]
        return try ApplicationLifecycle(
            services: descriptions.map { service in
                ManagedService(
                    id: service.id, dependencies: service.dependencies,
                    start: {
                        do { try await service.start() } catch {
                            services.containerFailures.report(
                                module: service.id, component: "lifecycle", operation: "start", phase: .startup,
                                error: error, includeCancellation: !Task.isCancelled)
                            throw error
                        }
                    }, invalidate: service.invalidate,
                    foreground: { active in
                        do { try await service.foreground(active) } catch {
                            services.containerFailures.report(
                                module: service.id, component: "lifecycle", operation: active ? "resume" : "suspend",
                                phase: .foreground, error: error, includeCancellation: !Task.isCancelled)
                            throw error
                        }
                    },
                    stop: {
                        do { try await service.stop() } catch {
                            services.containerFailures.report(
                                module: service.id, component: "lifecycle", operation: "stop", phase: .shutdown,
                                error: error, includeCancellation: !Task.isCancelled)
                            if let failure = error as? ServiceStopFailure {
                                for (index, cause) in failure.errors.enumerated() {
                                    services.containerFailures.report(
                                        module: service.id, component: "cleanup", operation: "stop.\(index)",
                                        phase: .cleanup, error: cause)
                                }
                            }
                            throw error
                        }
                    })
            })
    }
}
