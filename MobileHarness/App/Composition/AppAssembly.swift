import AppWorkflows
import Foundation
import ModelKit
import ModelKitDefaults
import Observation
import PlatformKit
import UI

/// The scene's composition root. Runtime services are lazy but never discovered by consumers.
@MainActor @Observable
final class AppAssembly {
    private(set) var container: AppContainer?
    @ObservationIgnored private var runtimeValue: ApplicationRuntime?
    @ObservationIgnored private let cameraDevice = AppleCamera()
    @ObservationIgnored private let resources = Bundle.main.bundleURL.appendingPathComponent("Models")
    @ObservationIgnored private lazy var settingsWorkflow = SettingsWorkflow(
        resources: resources,
        beginChange: { [weak self] in await self?.container?.lifecycle.beginSettingsChange() },
        endChange: { [weak self] in self?.container?.lifecycle.endSettingsChange() })
    @ObservationIgnored lazy var settings = SettingsState(
        operations: settingsWorkflow, initial: SettingsWorkflow.initial)
    @ObservationIgnored lazy var camera = makeCamera()
    private func makeCamera() -> CameraCoordinator {
        let device = cameraDevice
        return CameraCoordinator(
            camera: device, state: CameraState(),
            makeRuntime: { [weak self] in
                guard let self else { throw CancellationError() }
                return try self.runtime()
            },
            makeSession: { [weak self] in
                guard let self else { throw CancellationError() }
                let models = try await ModelKitDefaults.manager(resources: self.resources)
                let pose = try await models.get(.pose, load: false)
                return try VisionSession(runtime: self.runtime(), pose: pose)
            })
    }
    @ObservationIgnored lazy var history = makeHistory()
    private func makeHistory() -> ConversationHistoryWorkflow {
        ConversationHistoryWorkflow(
            state: ConversationHistoryState(),
            loadStore: { [weak self] in
                guard let self else { throw CancellationError() }
                await self.container?.lifecycle.beginSettingsChange()
                defer { self.container?.lifecycle.endSettingsChange() }
                try Task.checkCancellation()
                return try self.runtime().conversations
            },
            makeChat: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.settings.restore()
                await self.container?.lifecycle.beginSettingsChange()
                defer { self.container?.lifecycle.endSettingsChange() }
                try Task.checkCancellation()
                let models = try await ModelKitDefaults.manager(resources: self.resources)
                return CurrentChatCapability(models: models)
            })
    }
    private func runtime() throws -> ApplicationRuntime {
        if let runtimeValue { return runtimeValue }
        let runtime = try ApplicationRuntime(camera: cameraDevice)
        runtimeValue = runtime
        return runtime
    }
    func prepare(progress: @MainActor (String) -> Void) async throws {
        guard container == nil else { return }
        try await settings.restore()
        let workflow = settingsWorkflow
        let prepared = try await AppContainer(
            resources: resources, runtime: runtime(), modelName: { await workflow.modelName }, progress: progress)
        try Task.checkCancellation()
        container = prepared
    }
}
