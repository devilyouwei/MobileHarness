#if APP_COMPOSITION_ACCEPTANCE && os(iOS)
    import Actions
    import Agents
    import Foundation
    import Gateway
    import SwiftUI
    import UI

    private enum CompositionAcceptanceFailure: Error { case assertion(String) }

    @main @MainActor
    struct ProductionCompositionAcceptance: App {
        @State private var status = "Running production composition acceptance"
        var body: some Scene {
            WindowGroup {
                Text(status).task {
                    let output = URL.documentsDirectory.appendingPathComponent("composition-acceptance.json")
                    do {
                        try await verify()
                        status = "passed"
                        try JSONSerialization.data(withJSONObject: ["result": "passed"])
                            .write(to: output, options: .atomic)
                    } catch {
                        status = "failed: \(error)"
                        try? JSONSerialization.data(withJSONObject: ["result": "failed", "error": "\(error)"])
                            .write(to: output, options: .atomic)
                    }
                }
            }
        }

        private func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw CompositionAcceptanceFailure.assertion(message) }
        }

        private func verify() async throws {
            let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            guard let defaults = UserDefaults(suiteName: "composition-acceptance.\(UUID().uuidString)") else {
                throw CompositionAcceptanceFailure.assertion("Cannot create isolated preferences")
            }
            var created: ServiceFactories.Services?
            let composition = AppComposition(languageSettings: ApplicationLanguageSettings(defaults: defaults)) {
                language in
                let services = ServiceFactories.make(root: root, language: language)
                created = services
                return services
            }
            guard let services = created else { throw CompositionAcceptanceFailure.assertion("Missing factory scope") }
            do {
                composition.setForeground(true)
                // The UI bootstrap must use the same production ModuleRegistration graph.
                try await composition.features.prepare { _ in }
                try require(composition.features.startupIssue == nil, "Bootstrap failed")
                try require(
                    services.gateway.isAvailable && services.actions.state == .running, "Business roots not running")
                try require(services.registry.gateway() === services.gateway, "Gateway scope mismatch")
                try require(services.registry.ui() === services.uiContainer, "UI scope mismatch")
                try require(
                    composition.features.navigation === services.uiContainer.navigation.state, "Navigation not wired")
                // Goes through the installed UI request consumer and actual settings persistence.
                _ = try await services.uiContainer.settings.requests.submit(.restore)
                composition.features.navigate(.settings)
                try require(composition.features.navigation.path == [.settings], "Navigation receipt missing")
                composition.setForeground(false)
                composition.setForeground(true)
                try await composition.features.prepare { _ in }
                _ = try await services.uiContainer.settings.requests.submit(.restore)
                try await composition.stop()
                try require(
                    services.gateway.state == .stopped && services.actions.state == .stopped, "Roots did not stop")
                try require(!services.uiContainer.isAvailable, "UI remains available after stop")
                do {
                    _ = try await services.uiContainer.settings.requests.submit(.restore)
                    throw CompositionAcceptanceFailure.assertion("Stopped request channel accepted work")
                } catch is UIRequestError {}
                try await composition.stop()
            } catch {
                try await composition.stop()
                throw error
            }
        }
    }
#endif
