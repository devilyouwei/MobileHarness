import Foundation

/// Immutable composition input; never obtains credentials, models or native services itself.
public struct UIConfiguration: Sendable {
    public let settings: CloudSettingsDraft
    public let historyTitle: String
    public init(
        settings: CloudSettingsDraft = .init(enabled: false, url: "", key: "", model: ""),
        historyTitle: String = "Assistant"
    ) {
        self.settings = settings
        self.historyTitle = historyTitle
    }
}

@MainActor
public final class UIContainer {
    public func stateSnapshot() async throws -> UIStateSnapshot {
        try Task.checkCancellation()
        return UIStateSnapshot(
            path: "ui",
            runtime: [
                "started": .flag(admission.started), "stopped": .flag(admission.stopped),
                "cleanupJoined": .flag(cleanupJoined),
                "available": .flag(isAvailable), "rejectedUpdates": .unsigned(rejectedUpdates),
            ],
            children: [
                .init(path: "ui.island"), .init(path: "ui.windows"), .init(path: "ui.web"), .init(path: "ui.home"),
                .init(path: "ui.camera"),
                .init(path: "ui.settings"),
                .init(path: "ui.modelresources"), .init(path: "ui.navigation"), .init(path: "ui.album"),
                .init(path: "ui.history"), .init(path: "ui.devices"), .init(path: "ui.diagnostics"),
            ])
    }

    public func stateReaders() async throws -> [String: UIStateSnapshot.Reader] {
        var readers: [String: UIStateSnapshot.Reader] = [
            "ui": UIStateSnapshot.reader(of: self) { try await $0.stateSnapshot() }
        ]
        readers["ui.island"] = UIStateSnapshot.reader(of: island) { try await $0.stateSnapshot() }
        readers["ui.web"] = UIStateSnapshot.reader(of: web) { try await $0.stateSnapshot() }
        readers["ui.windows"] = UIStateSnapshot.reader(of: windows) { try await $0.stateSnapshot() }
        readers["ui.camera"] = UIStateSnapshot.reader(of: camera) { try await $0.stateSnapshot() }
        readers["ui.settings"] = UIStateSnapshot.reader(of: settings) { try await $0.stateSnapshot() }
        readers["ui.modelresources"] = UIStateSnapshot.reader(of: modelResources) { try await $0.stateSnapshot() }
        readers["ui.navigation"] = UIStateSnapshot.reader(of: navigation) { try await $0.stateSnapshot() }
        readers["ui.album"] = UIStateSnapshot.reader(of: album) { try await $0.stateSnapshot() }
        readers["ui.history"] = UIStateSnapshot.reader(of: history) { try await $0.stateSnapshot() }
        readers["ui.devices"] = UIStateSnapshot.reader(of: devices) { try await $0.stateSnapshot() }
        readers.merge(try await home.stateReaders()) { _, new in new }
        readers.merge(try await diagnostics.stateReaders()) { _, new in new }
        return readers
    }
    public let island: IslandState
    public let windows: WindowState = WindowState()
    public let web = WebPageContainer()
    public let home: UIHomeContainer
    public let camera: UICameraContainer
    public let settings: UISettingsContainer
    public let modelResources: UIModelResourcesContainer
    public let navigation: UINavigationContainer
    public let album: UIAlbumContainer = UIAlbumContainer()
    public let history: UIHistoryContainer
    public let devices: UIDeviceSettingsContainer
    public let diagnostics: UIDiagnosticsContainer
    private let admission = UIPresentationAdmission()
    private var cleanupJoined = false
    private var shutdown: Task<Void, Never>?
    private let onFailure: UIFailureReporting
    public init(
        configuration: UIConfiguration = .init(), systemStatus: IslandDeviceStatusReading? = nil,
        onFailure: @escaping UIFailureReporting = { _, _, _ in }
    ) {
        island = IslandState(systemStatus: systemStatus, onFailure: onFailure)
        self.onFailure = onFailure
        home = UIHomeContainer(admission: admission)
        camera = UICameraContainer(admission: admission, onFailure: onFailure)
        settings = UISettingsContainer(initial: configuration.settings, admission: admission)
        modelResources = UIModelResourcesContainer(admission: admission)
        navigation = UINavigationContainer(admission: admission)
        history = UIHistoryContainer(title: configuration.historyTitle, admission: admission)
        devices = UIDeviceSettingsContainer(admission: admission)
        diagnostics = UIDiagnosticsContainer(admission: admission)
        navigation.state.onHomeVisibilityChanged = { [weak windows, weak island] visible in
            windows?.isHostVisible = visible
            island?.setLocalPresentationVisible(visible)
        }
    }
    private func setInputAvailable(_ value: Bool) {
        windows.setAvailable(value)
        web.setAvailable(value)
        island.setAvailable(value)
        home.requests.setAvailable(value)
        home.listeningRequests.setAvailable(value)
        camera.requests.setAvailable(value)
        settings.requests.setAvailable(value)
        modelResources.requests.setAvailable(value)
        history.requests.setAvailable(value)
        album.requests.setAvailable(value)
        devices.requests.setAvailable(value)
        diagnostics.detectionRequests.setAvailable(value)
    }
    public var isAvailable: Bool { admission.active }
    public var rejectedUpdates: UInt64 { admission.rejected }
    public func start() throws(UIFailure) {
        guard !admission.stopped else {
            let failure = UIFailure(component: "root", operation: "start", underlying: UIContainerError.stopped)
            onFailure(failure.component, failure.operation, failure)
            throw failure
        }
        guard !admission.started else { return }
        admission.start()
        setInputAvailable(true)
        devices.startPresentation()
        camera.setAvailable(true)
    }
    public func invalidate() {
        setInputAvailable(false)
        admission.setActive(false)
        home.invalidate()
        camera.setAvailable(false)
    }
    /// Keep presentation facts and accepted voice work alive; only scene-bound surfaces stop.
    public func setSceneActive(_ active: Bool) throws(UIFailure) {
        guard admission.started, !admission.stopped else {
            throw UIFailure(component: "root", operation: "setSceneActive", underlying: UIContainerError.unavailable)
        }
        windows.setAvailable(active)
        web.setAvailable(active)
        camera.setAvailable(active)
        island.setSceneActive(active)
    }
    public func setForeground(_ active: Bool) throws(UIFailure) {
        guard !admission.stopped else {
            let failure = UIFailure(component: "root", operation: "setForeground", underlying: UIContainerError.stopped)
            onFailure(failure.component, failure.operation, failure)
            throw failure
        }
        guard admission.started else {
            let failure = UIFailure(
                component: "root", operation: "setForeground", underlying: UIContainerError.unavailable)
            onFailure(failure.component, failure.operation, failure)
            throw failure
        }
        if !active {
            invalidate()
        } else {
            admission.setActive(true)
            setInputAvailable(true)
            camera.setAvailable(true)
        }
    }
    public func stop() async {
        if let shutdown { return await shutdown.value }
        invalidate()
        settings.clearSensitiveDraft()
        devices.stopPresentation()
        admission.close()
        web.closeSessions()
        web.close()
        await windows.stop()
        await island.stop()
        home.requests.stop()
        home.listeningRequests.stop()
        diagnostics.detectionRequests.stop()
        camera.requests.stop()
        settings.requests.stop()
        modelResources.requests.stop()
        history.requests.stop()
        devices.requests.stop()
        let task = Task { [home, camera, album] in
            await album.stop()
            await home.stop()
            await camera.stop()
        }
        shutdown = task
        await task.value
        cleanupJoined = true
    }
}
