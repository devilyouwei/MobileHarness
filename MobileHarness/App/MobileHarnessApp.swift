import AppWorkflows
import ModelKitDefaults
import ModelKitHub
import ModelKitRuntime
import SwiftUI
import UI
import UIKit

@main
@MainActor
struct MobileHarnessApp: App {
    @UIApplicationDelegateAdaptor(ModelDownloadsAppDelegate.self) private var downloadsDelegate
    @State private var assembly = AppAssembly()
    private var camera: CameraCoordinator { assembly.camera }
    private var container: AppContainer? { assembly.container }
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var startupError: String?
    @State private var startupStatus = "正在准备…"
    @State private var startupAttempt = 0
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Group {
                    if isVisualPreview {
                        visualPreview
                    } else if isDiagnostic {
                        startupContent
                    } else {
                        CameraConversationSurface(
                            camera: camera.state, controls: camera,
                            openSettings: {
                                container?.lifecycle.stopVoice()
                                showingSettings = true
                            }
                        ) {
                            CameraPreviewAdapter(
                                source: camera.preview,
                                facing: camera.state.facing == .front ? .front : .back, skeleton: camera.state.skeleton)
                        } content: {
                            startupContent
                        }
                    }
                }
                .navigationTitle("首页")
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $showingSettings) {
                    SettingsView(
                        settings: assembly.settings, bluetooth: assembly.bluetooth.state,
                        bluetoothControls: assembly.bluetooth, history: assembly.history.state,
                        historyControls: assembly.history, modelResources: assembly.modelResources
                    ) {
                        let applied = await assembly.settings.save()
                        if applied, container == nil {
                            startupError = nil
                            startupStatus = "正在准备…"
                            startupAttempt += 1
                        }
                        return applied
                    }

                }
            }
            .task {
                if !isVisualPreview && !isDiagnostic {
                    assembly.bluetooth.setForeground(scenePhase == .active)
                    await assembly.bluetooth.run()
                }
            }
            .task {
                if !isVisualPreview && !isDiagnostic {
                    camera.setForeground(scenePhase == .active && !showingSettings)
                    await camera.observe()
                }
            }
            .onChange(of: showingSettings) { _, showing in
                if !isVisualPreview && !isDiagnostic { camera.setForeground(scenePhase == .active && !showing) }
            }
            .onChange(of: keepsHomeScreenAwake, initial: true) { _, keepsAwake in
                UIApplication.shared.isIdleTimerDisabled = keepsAwake
            }
            .onChange(of: scenePhase) { _, phase in
                if !isVisualPreview && !isDiagnostic {
                    camera.setForeground(phase == .active && !showingSettings)
                    assembly.bluetooth.setForeground(phase == .active)
                    if phase == .background { container?.lifecycle.stopVoice(message: "已进入后台，轻触重新开始") }
                }
            }
            .task(id: container.map { ObjectIdentifier($0) }) {
                if let container, !isDiagnostic { await container.lifecycle.run() }
            }
            .task(id: startupAttempt) {
                if !isVisualPreview { await prepare() }
            }
        }
    }

    private var keepsHomeScreenAwake: Bool {
        scenePhase == .active && !showingSettings && !isDiagnostic && !isVisualPreview
    }

    @ViewBuilder
    private var visualPreview: some View {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-actions-preview") {
                ActionActivityVisualPreview()
            } else {
                ConversationVisualPreview()
            }
        #else
            EmptyView()
        #endif
    }

    private var isVisualPreview: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains("-conversation-preview")
                || ProcessInfo.processInfo.arguments.contains("-actions-preview")
        #else
            false
        #endif
    }

    private var isDiagnostic: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
            if arguments.contains("-gemma4-validation") { return true }
        #endif
        return arguments.contains("-moss-benchmark")
    }

    private var startupContent: some View {
        Group {
            if let container {
                content(container)
            } else {
                ConversationStartupView(status: startupStatus, error: startupError) {
                    startupError = nil
                    startupStatus = "正在准备…"
                    startupAttempt += 1
                }
            }
        }
    }

    private func prepare() async {
        guard container == nil, startupError == nil else { return }
        do {
            try await assembly.prepare { startupStatus = $0 }
        } catch is CancellationError {
            // A disappearing scene must not publish a partially prepared container.
        } catch { startupError = String(describing: error) }
    }
    @ViewBuilder
    private func content(_ container: AppContainer) -> some View {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-gemma4-validation") {
                container.makeChatValidationView()
            } else {
                standardContent(container)
            }
        #else
            standardContent(container)
        #endif
    }
    @ViewBuilder
    private func standardContent(_ container: AppContainer) -> some View {
        if ProcessInfo.processInfo.arguments.contains("-moss-benchmark") {
            container.makeMossValidationView()
        } else {
            ConversationView(
                state: container.conversation, robot: assembly.bluetooth.state, activity: container.actionActivity,
                toggleVoice: container.lifecycle.toggleVoice)
        }
    }

}

@MainActor
final class ModelDownloadsAppDelegate: NSObject, UIApplicationDelegate {
    private var completions: [String: (UUID, () -> Void)] = [:]
    private var preparationTime: UIBackgroundTaskIdentifier = .invalid
    private var preparationTimer: Task<Void, Never>?
    func applicationDidEnterBackground(_ application: UIApplication) {
        finishPreparationTime()
        preparationTime = application.beginBackgroundTask(withName: "Model download preparation") { [weak self] in
            self?.finishPreparationTime()
        }
        preparationTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            self?.finishPreparationTime()
        }
    }
    func applicationWillEnterForeground(_ application: UIApplication) { finishPreparationTime() }
    private func finishPreparationTime() {
        preparationTimer?.cancel()
        preparationTimer = nil
        if preparationTime != .invalid {
            UIApplication.shared.endBackgroundTask(preparationTime)
            preparationTime = .invalid
        }
    }

    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier.hasPrefix("dev.mobileharness.artifacts.") else {
            completionHandler()
            return
        }
        completions.removeValue(forKey: identifier)?.1()
        let generation = UUID()
        completions[identifier] = (generation, completionHandler)
        Task {
            do {
                let root = URL.applicationSupportDirectory.appendingPathComponent("MobileHarness/Models")
                let catalog = try ModelArtifactCatalog.read(
                    Bundle.main.bundleURL.appendingPathComponent("Models/model-catalog.json"))
                let storage = try ModelArtifactStorageAdapter(root: root)
                let manager = try await ModelKitDefaults.configureArtifacts(
                    resources: root.appendingPathComponent("installed"), catalog: catalog, storage: storage,
                    downloader: HuggingFaceArtifactDownloader())
                _ = try await manager.artifactSnapshots()
            } catch {
                // Persisted index/catalog failures are surfaced again by the resource settings page.
                finish(identifier, generation: generation)
            }
        }
        ModelArtifactBackgroundEvents.register(identifier) { [weak self] in
            Task { @MainActor in self?.finish(identifier, generation: generation) }
        }
    }
    private func finish(_ identifier: String, generation: UUID) {
        guard completions[identifier]?.0 == generation else { return }
        completions.removeValue(forKey: identifier)?.1()
    }

}
