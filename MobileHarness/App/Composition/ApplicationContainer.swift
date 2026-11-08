import Actions
import Agents
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
    /// Structural projection only. Each independent SDK retains its own Failure definition.
    public nonisolated static func failureDetails(_ error: any Error) -> ContainerFailureDetails? {
        switch error {
        case let failure as ActionsFailure:
            return ContainerFailureDetails(code: failure.code.rawValue, isCancellation: failure.isCancellation)
        case let failure as GatewayFailure:
            return ContainerFailureDetails(code: failure.code.rawValue, isCancellation: failure.isCancellation)
        case let failure as AgentFailure:
            return ContainerFailureDetails(code: failure.code.rawValue, isCancellation: failure.isCancellation)
        case let failure as StorageFailure:
            return ContainerFailureDetails(code: failure.code.rawValue, isCancellation: failure.isCancellation)
        case let failure as PlatformFailure:
            return ContainerFailureDetails(code: failure.code.rawValue, isCancellation: failure.isCancellation)
        case let failure as ModelFailure:
            return ContainerFailureDetails(code: failure.code.rawValue, isCancellation: failure.isCancellation)
        case let failure as UIFailure:
            return ContainerFailureDetails(code: failure.code.rawValue, isCancellation: failure.isCancellation)
        default: return nil
        }
    }
    #if os(iOS)
        @MainActor private var agentRoot: AnyObject?
        /// Explicit application assembly is evaluated once per registry, never by a business consumer.
        @available(iOS 27, *)
        @MainActor public func agents(make: @MainActor () -> AgentContainer) -> AgentContainer {
            if let agentRoot = agentRoot as? AgentContainer { return agentRoot }
            let value = make()
            agentRoot = value
            return value
        }
    #endif
    public var containerFailures: Factory<ContainerFailureChannel> { self { ContainerFailureChannel() }.cached }
    @MainActor public func registerActions(_ root: ActionsContainer) {
        actions.register { root }
    }
    @MainActor public var actions: Factory<ActionsContainer> {
        self {
            MainActor.assumeIsolated {
                ActionsContainer(onFailure: { [failures = self.containerFailures()] failure in
                    failures.report(
                        module: "actions", component: "container", operation: failure.operation,
                        error: failure,
                        details: .init(code: failure.code.rawValue, isCancellation: failure.isCancellation))
                })
            }
        }.cached
    }
    @MainActor public var gateway: Factory<GatewayContainer> {
        self {
            MainActor.assumeIsolated {
                GatewayContainer(onFailure: { [failures = self.containerFailures()] failure in
                    failures.report(
                        module: "gateway", component: failure.component, operation: failure.operation,
                        error: failure,
                        details: .init(code: failure.code.rawValue, isCancellation: failure.isCancellation))
                })
            }
        }.cached
    }
    @MainActor public var ui: Factory<UIContainer> {
        self {
            MainActor.assumeIsolated {
                UIContainer(
                    configuration: self.uiConfiguration,
                    systemStatus: { [platform = self.platform()] in
                        let value = try platform.systemStatus()
                        let network: IslandDeviceStatus.Network
                        switch value.network {
                        case .unknown: network = .unknown
                        case .offline: network = .offline
                        case .wifi: network = .wifi
                        case .cellular: network = .cellular
                        case .wired: network = .wired
                        case .other: network = .other
                        }
                        return .init(
                            network: network, batteryLevel: value.batteryLevel,
                            charging: value.charging, lowPower: value.lowPower)
                    },
                    onFailure: self.containerFailures().sink(module: "ui", details: Self.failureDetails))
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
    @MainActor public var islandPresentation: Factory<IslandState> { self { self.ui().island }.cached }
    @MainActor public var windowPresentation: Factory<WindowState> { self { self.ui().windows }.cached }
    @MainActor public var navigationPresentation: Factory<UINavigationContainer> {
        self { MainActor.assumeIsolated { self.ui().navigation } }
    }
    @MainActor public var albumPresentation: Factory<UIAlbumContainer> {
        self { MainActor.assumeIsolated { self.ui().album } }
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
                        module: "model",
                        details: Self.failureDetails))
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
            MainActor.assumeIsolated {
                PlatformContainer(
                    onFailure: self.containerFailures().sink(module: "platform", details: Self.failureDetails))
            }
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
            let failures = StorageFailureReporter(
                receive: self.containerFailures().sink(module: "storage", details: Self.failureDetails))
            let files = FilesContainer(
                settings: self.root.appendingPathComponent("Settings", isDirectory: true),
                photos: self.root.appendingPathComponent("CapturedPhotos", isDirectory: true),
                models: self.root.appendingPathComponent("Models", isDirectory: true),
                workspaces: self.root.appendingPathComponent("ArtifactWorkspaces", isDirectory: true),
                failures: failures)
            return StorageContainer(
                database: SQLiteDatabaseFactory.make(
                    databaseURL: self.root.appendingPathComponent("records.sqlite"),
                    resetWriterFilesAt: self.root.appendingPathComponent("ArtifactWorkspaces", isDirectory: true),
                    failures: failures),
                files: files, failures: failures)
        }.cached
    }
    public var cache: Factory<CacheContainer> { self { self.storage().cache } }
    public var files: Factory<FilesContainer> { self { self.storage().files } }
    public var database: Factory<any DatabaseStorage> { self { self.storage().database } }
}
