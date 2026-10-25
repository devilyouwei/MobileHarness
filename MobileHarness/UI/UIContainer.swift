import Foundation
import Observation

public typealias UIFailureReporting = @Sendable (String, String, any Error) -> Void
public enum UIContainerError: Error, Sendable, Equatable { case unavailable, stopped, stale }

@MainActor
public protocol UIPresentationAccess: AnyObject, Sendable {
    var isPresentationAvailable: Bool { get }
}
extension UIPresentationAccess {
    public func requirePresentation() throws {
        guard isPresentationAvailable else { throw UIContainerError.unavailable }
    }
}

/// Opaque display lifetime only; grants no device or business authority.
public struct UIPresentationToken: Sendable, Equatable {
    fileprivate let root: UUID
    fileprivate let generation: UInt64
}

@MainActor
final class UIPresentationAdmission {
    private let root = UUID()
    private(set) var generation: UInt64 = 0
    private(set) var started = false
    private(set) var active = false
    private(set) var stopped = false
    private(set) var rejected: UInt64 = 0
    var token: UIPresentationToken { .init(root: root, generation: generation) }
    func acceptsRetained() -> Bool {
        guard started, !stopped else {
            rejected &+= 1
            return false
        }
        return true
    }
    func acceptsLive(_ token: UIPresentationToken? = nil) -> Bool {
        guard started, !stopped, active, token == nil || token == self.token else {
            rejected &+= 1
            return false
        }
        return true
    }
    func requireLive(_ token: UIPresentationToken? = nil) throws {
        guard acceptsLive(token) else { throw stopped ? UIContainerError.stopped : UIContainerError.unavailable }
    }
    func start() {
        started = true
        active = true
    }
    func setActive(_ value: Bool) {
        if active && !value { generation &+= 1 }
        active = value && started && !stopped
    }
    func close() {
        setActive(false)
        stopped = true
    }
}

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
    private var shutdown: Task<Void, Never>?
    private let onFailure: UIFailureReporting
    public init(configuration: UIConfiguration = .init(), onFailure: @escaping UIFailureReporting = { _, _, _ in }) {
        self.onFailure = onFailure
        home = UIHomeContainer(admission: admission)
        camera = UICameraContainer(admission: admission, onFailure: onFailure)
        settings = UISettingsContainer(initial: configuration.settings, admission: admission)
        modelResources = UIModelResourcesContainer(admission: admission)
        navigation = UINavigationContainer(admission: admission)
        history = UIHistoryContainer(title: configuration.historyTitle, admission: admission)
        devices = UIDeviceSettingsContainer(admission: admission)
        diagnostics = UIDiagnosticsContainer(admission: admission)
    }
    private func setInputAvailable(_ value: Bool) {
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
    }
}

@MainActor
public final class UINavigationContainer {
    public let state = NavigationState()
    public var presentation: any NavigationPresenting { state }
    init(admission: UIPresentationAdmission) { state.presentationAdmission = admission }
}

public enum AppDestination: String, Codable, Hashable, Sendable {
    case settings, language, recognition, synthesis, vision, bluetooth, history, album
}
@MainActor
@Observable
public final class NavigationState {
    @ObservationIgnored var presentationAdmission: UIPresentationAdmission?
    public var isPresentationAvailable: Bool { presentationAdmission.map { $0.started && !$0.stopped } ?? true }

    public internal(set) var path: [AppDestination] = [] {
        didSet {
            generation = UUID()
            phase = .transitioning
            overlay = nil
            content = .idle
        }
    }
    public enum Phase: String, Encodable, Sendable { case transitioning, settled }
    public struct ContextSnapshot: Encodable, Sendable, Equatable {
        public let path: [AppDestination]
        public let phase: Phase
        public let current: NavigationLocation?
        public let overlay: PageOverlay?
        public let content: PageContent
        public let operation: PageOperation?
        private enum CodingKeys: String, CodingKey { case path, phase, current, overlay, content, operation }
        public func encode(to encoder: any Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(path, forKey: .path)
            try fields.encode(phase, forKey: .phase)
            try fields.encode(current, forKey: .current)
            try fields.encode(overlay, forKey: .overlay)
            try fields.encode(content, forKey: .content)
            try fields.encode(operation, forKey: .operation)
        }
    }
    public private(set) var generation = UUID()
    private var phase: Phase = .transitioning
    private var current: NavigationLocation?
    private var overlay: PageOverlay?
    private var content: PageContent = .idle
    @discardableResult
    public func confirm(
        _ location: NavigationLocation, content: PageContent = .ready, overlay: PageOverlay? = nil,
        generation: UUID
    ) -> Bool {
        guard generation == self.generation, isPresentationAvailable else { return false }
        let destination = path.last?.rawValue ?? "home"
        let allowed =
            location.page.rawValue == destination
            || (destination == "album" && location.page == .albumPhoto)
            || (destination == "history" && [.agentRecords, .conversation, .turn].contains(location.page))
        guard allowed else { return false }
        self.current = location
        self.content = content
        self.overlay = overlay
        phase = .settled
        return true
    }
    public func updateContext(
        _ location: NavigationLocation, content: PageContent, overlay: PageOverlay?, generation: UUID
    ) {
        guard current == location else { return }
        confirm(location, content: content, overlay: overlay, generation: generation)
    }
    public func contextSnapshot(album: UIAlbumContainer.ContextSnapshot? = nil) -> ContextSnapshot {
        let isAlbum = phase == .settled && current.map { [.album, .albumPhoto].contains($0.page) } == true
        return ContextSnapshot(
            path: path, phase: phase, current: current, overlay: overlay,
            content: isAlbum && current?.page == .album ? album?.content ?? content : content,
            operation: isAlbum ? album?.operation : nil)
    }
    public init() {}
    public func show(_ destination: AppDestination?) {
        guard presentationAdmission?.acceptsRetained() ?? true else { return }
        guard let destination else {
            path = []
            return
        }
        path = destination == .settings ? [.settings] : [.settings, destination]
    }

    @discardableResult
    public func present(_ update: NavigationUpdate) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        apply(update)
        return true
    }
    func apply(_ update: NavigationUpdate) {
        switch update {
        case .path(let value): path = value
        }
    }
}

public enum NavigationUpdate {
    case path([AppDestination])
}

@MainActor
public protocol NavigationPresenting: UIPresentationAccess {
    var path: [AppDestination] { get }
    @discardableResult
    func present(_ update: NavigationUpdate) -> Bool
    func show(_ destination: AppDestination?)
}

extension NavigationState: NavigationPresenting {}
