import AgentBindings
import AppLifecycle
import Foundation
import Observation

@MainActor @Observable final class AppComposition {
    private var services: ServiceFactories.Services
    private var owner: Result<ApplicationLifecycle, any Error>
    private var foreground = false
    private var replacement: Task<Void, Never>?
    private(set) var scopeID = UUID()
    var features: AgentApplicationUI { services.ui }

    init() {
        let created = ServiceFactories.make()
        services = created
        owner = Result { try ModuleRegistration.lifecycle(created) }
        connect()
    }
    private func connect() {
        let selected = scopeID
        features.bootstrap = { [weak self] in
            guard let self, selected == self.scopeID else { throw CancellationError() }
            try await self.startScope()
        }
        if case .success(let lifecycle) = owner {
            lifecycle.onFailure = features.reportStartupFailure
            lifecycle.setForeground(foreground)
        }
        features.onRetry = { [weak self] in self?.retry() }
    }
    private func startScope() async throws {
        let selected = scopeID
        let lifecycle = try owner.get()
        do { try await lifecycle.start() } catch is CancellationError
            where lifecycle.state == .suspended || lifecycle.state == .stopping || lifecycle.state == .stopped
        {
            if selected == scopeID, foreground, lifecycle.state == .suspended { retry() }
            throw CancellationError()
        }
        guard selected == scopeID else { throw CancellationError() }
    }
    func start() async {
        let selected = scopeID
        do { try await startScope() } catch is CancellationError {} catch {
            if selected == scopeID { features.reportStartupFailure(error) }
        }
    }
    func setForeground(_ foreground: Bool) {
        self.foreground = foreground
        do {
            let lifecycle = try owner.get()
            lifecycle.setForeground(foreground)
            if foreground, lifecycle.state == .suspended { retry() }
        } catch { features.reportStartupFailure(error) }
    }
    private func retry() {
        guard replacement == nil else { return }
        replacement = Task {
            defer {
                replacement = nil
                if foreground, case .success(let lifecycle) = owner, lifecycle.state == .suspended { retry() }
            }
            do {
                if case .success(let lifecycle) = owner { try await lifecycle.stop() }
                services = ServiceFactories.make()
                owner = Result { try ModuleRegistration.lifecycle(services) }
                scopeID = UUID()
                connect()
                setForeground(foreground)
                await start()
            } catch { features.reportStartupFailure(error) }
        }
    }
}
