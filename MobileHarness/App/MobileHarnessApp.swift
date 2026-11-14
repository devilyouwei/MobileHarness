import Actions
import SwiftUI
import UI

@main @MainActor
struct MobileHarnessApp: App {
    @UIApplicationDelegateAdaptor(ApplicationSystemDelegate.self) private var delegate
    @State private var composition = AppComposition()
    @Environment(\.scenePhase) private var phase
    init() {
        let composition = self.composition
        delegate.connect { try await composition.prepareBackgroundArtifacts() }
    }
    var body: some Scene {
        WindowGroup {
            ApplicationRootView(
                services: composition.features,
                languagePreference: Binding(
                    get: { composition.languageSettings.preference },
                    set: { composition.languageSettings.select($0) })
            )
            .environment(\.locale, composition.languageSettings.language.locale)
            .onChange(of: composition.languageSettings.language) { _, _ in composition.features.updateLanguage() }
            .id(composition.scopeID)
            .task { await composition.start() }
            .onChange(of: phase, initial: true) { _, phase in
                switch phase {
                case .active: composition.setForeground(true)
                case .inactive, .background: composition.setForeground(false)
                @unknown default: composition.setForeground(false)
                }
            }
        }
    }
}
