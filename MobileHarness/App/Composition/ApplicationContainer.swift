import FactoryKit
import Foundation
import Gateway
import ModelKit
import ModelKitDefaults
import PlatformKit
import Storage
import StorageCache
import StorageCore
import StorageDatabase
import StorageFiles
import StorageSQLite
import StorageState
import UI

/// Instance-local registration; the App owns asynchronous startup and shutdown explicitly.
public final class ApplicationContainer: ManagedContainer, @unchecked Sendable {
    public let manager = ContainerManager()
    private let root: URL
    private let uiConfiguration: UIConfiguration
    private let modelArtifacts: @Sendable (FilesContainer) async throws -> ModelArtifactConfiguration
    public init(
        root: URL, uiConfiguration: UIConfiguration = .init(),
        modelArtifacts: @escaping @Sendable (FilesContainer) async throws -> ModelArtifactConfiguration = { _ in
            throw CocoaError(.fileReadNoSuchFile)
        }
    ) {
        self.root = root
        self.uiConfiguration = uiConfiguration
        self.modelArtifacts = modelArtifacts
    }
    public var containerFailures: Factory<ContainerFailureChannel> { self { ContainerFailureChannel() }.cached }
    @MainActor public var ui: Factory<UIContainer> {
        self {
            MainActor.assumeIsolated {
                UIContainer(configuration: self.uiConfiguration, onFailure: self.containerFailures().sink(module: "ui"))
            }
        }.cached
    }
    @MainActor public var homePresentation: Factory<UIHomeContainer> {
        self { MainActor.assumeIsolated { self.ui().home } }
    }
    @MainActor public var settingsPresentation: Factory<UISettingsContainer> {
        self { MainActor.assumeIsolated { self.ui().settings } }
    }
    @MainActor public var modelResourcesPresentation: Factory<UIModelResourcesContainer> {
        self { MainActor.assumeIsolated { self.ui().modelResources } }
    }
    @MainActor public var navigationPresentation: Factory<UINavigationContainer> {
        self { MainActor.assumeIsolated { self.ui().navigation } }
    }
    @MainActor public var historyPresentation: Factory<UIHistoryContainer> {
        self { MainActor.assumeIsolated { self.ui().history } }
    }
    @MainActor public var devicesPresentation: Factory<UIDeviceSettingsContainer> {
        self { MainActor.assumeIsolated { self.ui().devices } }
    }
    @MainActor public var diagnosticsPresentation: Factory<UIDiagnosticsContainer> {
        self { MainActor.assumeIsolated { self.ui().diagnostics } }
    }
    @MainActor public var cameraPresentation: Factory<UICameraContainer> {
        self { MainActor.assumeIsolated { self.ui().camera } }
    }
    @MainActor public var model: Factory<ModelContainer> {
        self {
            MainActor.assumeIsolated {
                ModelContainer(
                    resources: self.root.appendingPathComponent("Models/installed", isDirectory: true),
                    prepareArtifacts: { [files = self.files(), configure = self.modelArtifacts] in
                        try await configure(files)
                    },
                    onFailure: self.containerFailures().sink(
                        module: "model", shouldPublish: { !($0 is InferenceAdmissionError) }))
            }
        }.cached
    }
    @MainActor public var languageModels: Factory<ModelLanguageContainer> {
        self { MainActor.assumeIsolated { self.model().language } }
    }
    @MainActor public var speechModels: Factory<ModelSpeechContainer> {
        self { MainActor.assumeIsolated { self.model().speech } }
    }
    @MainActor public var visionModels: Factory<ModelVisionContainer> {
        self { MainActor.assumeIsolated { self.model().vision } }
    }
    @MainActor public var modelArtifactsCapability: Factory<ModelArtifactsContainer> {
        self { MainActor.assumeIsolated { self.model().artifacts } }
    }
    @MainActor public var platform: Factory<PlatformContainer> {
        self {
            MainActor.assumeIsolated { PlatformContainer(onFailure: self.containerFailures().sink(module: "platform")) }
        }.cached
    }
    @MainActor public var audio: Factory<AudioContainer> { self { MainActor.assumeIsolated { self.platform().audio } } }
    @MainActor public var vision: Factory<VisionContainer> {
        self { MainActor.assumeIsolated { self.platform().vision } }
    }
    @MainActor public var connectivity: Factory<ConnectivityContainer> {
        self { MainActor.assumeIsolated { self.platform().connectivity } }
    }
    public var storage: Factory<StorageContainer> {
        self {
            let failures = StorageFailureReporter(receive: self.containerFailures().sink(module: "storage"))
            let files = FilesContainer(
                settings: self.root.appendingPathComponent("Settings", isDirectory: true),
                photos: self.root.appendingPathComponent("CapturedPhotos", isDirectory: true),
                models: self.root.appendingPathComponent("Models", isDirectory: true), failures: failures)
            return StorageContainer(
                database: SQLiteDatabaseFactory.make(
                    databaseURL: self.root.appendingPathComponent("records.sqlite"), failures: failures),
                files: files, failures: failures)
        }.cached
    }
    public var state: Factory<StateContainer> { self { self.storage().state } }
    public var cache: Factory<CacheContainer> { self { self.storage().cache } }
    public var files: Factory<FilesContainer> { self { self.storage().files } }
    public var database: Factory<any DatabaseStorage> { self { self.storage().database } }
}
