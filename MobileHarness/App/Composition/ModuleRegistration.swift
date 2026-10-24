import Agents
import AppLifecycle
import AppStorage
import Foundation
import Gateway

@MainActor enum ModuleRegistration {
    static func lifecycle(_ services: ServiceFactories.Services) throws -> ApplicationLifecycle {
        let descriptions = [
            ManagedService(
                id: "diagnostics", start: { services.containerFailures.start() },
                stop: { await services.containerFailures.stop() }),
            ManagedService(
                id: "storage", dependencies: ["diagnostics"], start: { try await services.storage.start() },
                stop: { try await services.storage.stop() }),
            ManagedService(
                id: "model", dependencies: ["storage", "diagnostics"],
                start: { try await services.model.start() }, invalidate: services.model.invalidate,
                foreground: { try await services.model.setForeground($0) },
                stop: { try await services.model.stop() }),
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
                id: "agents", dependencies: ["storage", "platform", "ui", "model"],
                start: services.agents.start,
                invalidate: services.agents.invalidate,
                foreground: services.agents.setForeground,
                stop: services.agents.stop),
            ManagedService(
                id: "homePreparation", dependencies: ["agents"], start: {},
                invalidate: { services.homePreparation.setActive(false) },
                foreground: { active in
                    services.homePreparation.setActive(
                        active && services.ui.preparesHomeModels && services.ui.navigation.path.isEmpty)
                }, stop: { await services.homePreparation.stop() }),
        ]
        return try ApplicationLifecycle(
            services: descriptions.map { service in
                ManagedService(
                    id: service.id, dependencies: service.dependencies,
                    start: {
                        do { try await service.start() } catch {
                            services.containerFailures.report(
                                module: service.id, component: "lifecycle", operation: "start", phase: .startup,
                                error: error, includeCancellation: !Task.isCancelled,
                                details: ApplicationContainer.failureDetails(error))
                            if ApplicationContainer.failureDetails(error)?.isCancellation == true {
                                throw CancellationError()
                            }
                            throw error
                        }
                    }, invalidate: service.invalidate,
                    foreground: { active in
                        do { try await service.foreground(active) } catch {
                            services.containerFailures.report(
                                module: service.id, component: "lifecycle", operation: active ? "resume" : "suspend",
                                phase: .foreground, error: error, includeCancellation: !Task.isCancelled,
                                details: ApplicationContainer.failureDetails(error))
                            if ApplicationContainer.failureDetails(error)?.isCancellation == true {
                                throw CancellationError()
                            }
                            throw error
                        }
                    },
                    stop: {
                        do { try await service.stop() } catch {
                            services.containerFailures.report(
                                module: service.id, component: "lifecycle", operation: "stop", phase: .shutdown,
                                error: error, includeCancellation: !Task.isCancelled,
                                details: ApplicationContainer.failureDetails(error))
                            if ApplicationContainer.failureDetails(error)?.isCancellation == true {
                                throw CancellationError()
                            }
                            throw error
                        }
                    })
            })
    }
}
