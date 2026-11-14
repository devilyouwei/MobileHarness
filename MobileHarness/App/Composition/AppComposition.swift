import Actions
import Agents
import AppLifecycle
import Foundation
import Observation
import Synchronization
import UI

@MainActor @Observable final class ApplicationLanguageSettings {
    private static let key = "application.language"
    private let defaults: UserDefaults
    private let preferredLanguage: () -> String?
    private let snapshot: Mutex<AppLanguage>
    private(set) var preference: AppLanguagePreference
    private(set) var language: AppLanguage

    init(
        defaults: UserDefaults = .standard,
        preferredLanguage: @escaping () -> String? = { Locale.preferredLanguages.first }
    ) {
        self.defaults = defaults
        self.preferredLanguage = preferredLanguage
        let preference = AppLanguagePreference(storedValue: defaults.string(forKey: Self.key))
        let language = preference.resolve(preferredLanguage: preferredLanguage())
        self.preference = preference
        self.language = language
        snapshot = Mutex(language)
    }

    nonisolated func read() -> AppLanguage { snapshot.withLock { $0 } }

    func select(_ preference: AppLanguagePreference) {
        guard preference != self.preference else { return }
        defaults.set(preference.rawValue, forKey: Self.key)
        self.preference = preference
        refresh()
    }

    func refresh() {
        let resolved = preference.resolve(preferredLanguage: preferredLanguage())
        guard language != resolved else { return }
        snapshot.withLock { $0 = resolved }
        language = resolved
    }
}

@MainActor @Observable final class AppComposition {
    private var services: ServiceFactories.Services
    let languageSettings: ApplicationLanguageSettings
    private let writerBackground: WriterContinuedProcessing
    private var owner: Result<ApplicationLifecycle, any Error>
    private var foreground = false
    private var replacement: Task<Void, Never>?
    private(set) var scopeID = UUID()
    private var backgroundArtifactsPrepared = false
    func prepareBackgroundArtifacts() async throws {
        backgroundArtifactsPrepared = true
        try await services.model.artifacts.prepare()
    }
    var features: ApplicationPresentation { services.ui }

    init() {
        let languageSettings = ApplicationLanguageSettings()
        self.languageSettings = languageSettings
        writerBackground = WriterContinuedProcessing(language: languageSettings.read)
        let created = ServiceFactories.make(language: languageSettings.read)
        services = created
        owner = Result { try ModuleRegistration.lifecycle(created) }
        connect()
    }
    private func connect() {
        services.agents.writer.bindBackgroundExecution(writerBackground.start)
        let selected = scopeID
        features.bootstrap = { [weak self] in
            guard let self, selected == self.scopeID else { throw CancellationError() }
            try await self.startScope()
        }
        if case .success(let lifecycle) = owner {
            lifecycle.onFailure = features.reportStartupFailure
            lifecycle.setForeground(foreground)
        } else if case .failure(let error) = owner {
            services.containerFailures.report(
                module: "app", component: "lifecycle", operation: "assemble", phase: .startup, error: error)
        }
        features.onHomeVisibilityChanged = { [weak self] visible in
            guard let self, selected == self.scopeID else { return }
            let running = (try? self.owner.get().state) == .running
            self.services.homePreparation.setActive(
                visible && self.foreground && running && self.features.preparesHomeModels)
        }
        features.onPreparationRequested = { [weak self] in
            guard let self, selected == self.scopeID else { return }
            self.services.homePreparation.refresh()
        }
        features.onInteractionActivityChanged = { [weak self] in
            guard let self, selected == self.scopeID,
                self.services.homePreparation.state == .deferred,
                !self.services.uiContainer.home.conversation.hasActiveInteraction
            else { return }
            self.services.homePreparation.refresh()
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
        if foreground { languageSettings.refresh() }
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
                await services.homePreparation.stop()
                if backgroundArtifactsPrepared {
                    try await services.model.stop()
                    try await services.storage.stop()
                }
                backgroundArtifactsPrepared = false
                services = ServiceFactories.make(language: languageSettings.read)
                owner = Result { try ModuleRegistration.lifecycle(services) }
                scopeID = UUID()
                connect()
                setForeground(foreground)
                await start()
            } catch { features.reportStartupFailure(error) }
        }
    }
}
