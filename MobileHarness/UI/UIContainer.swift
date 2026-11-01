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
                .init(path: "ui.windows"), .init(path: "ui.home"), .init(path: "ui.camera"), .init(path: "ui.settings"),
                .init(path: "ui.modelresources"), .init(path: "ui.navigation"), .init(path: "ui.album"),
                .init(path: "ui.history"), .init(path: "ui.devices"), .init(path: "ui.diagnostics"),
            ])
    }

    public func stateReaders() async throws -> [String: UIStateSnapshot.Reader] {
        var readers: [String: UIStateSnapshot.Reader] = [
            "ui": UIStateSnapshot.reader(of: self) { try await $0.stateSnapshot() }
        ]
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
    public let windows: WindowState = WindowState()
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
        windows.setAvailable(value)
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
        await windows.stop()
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

@MainActor
public final class UINavigationContainer {
    public func stateSnapshot() async throws -> UIStateSnapshot {
        try Task.checkCancellation()
        let value = state.contextSnapshot()
        return UIStateSnapshot(
            path: "ui.navigation",
            business: [
                "depth": .count(state.path.count), "path": .texts(value.path.map(\.rawValue)),
                "phase": .text(value.phase.rawValue),
                "current": value.current.map {
                    .object(["page": .text($0.page.rawValue), "itemID": $0.itemID.map { .text($0) } ?? .unknown])
                } ?? .unknown,
                "overlay": value.overlay.map { .text($0.rawValue) } ?? .unknown,
                "content": .text(value.content.rawValue),
            ],
            runtime: ["available": .flag(state.isPresentationAvailable)])
    }

    public let state = NavigationState()
    public var presentation: any NavigationPresenting { state }
    init(admission: UIPresentationAdmission) {
        state.presentationAdmission = admission
    }
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

/// Module-local, explicitly projected facts. This type never inspects private storage.
public struct UIStateSnapshot: Codable, Sendable {
    public struct Reference: Codable, Sendable, Hashable {
        public let path: String
        public init(path: String) { self.path = path }
    }
    public enum ReadError: Error, Sendable { case ownerReleased }
    public typealias Reader = @Sendable () async throws -> UIStateSnapshot
    /// Runtime capability only. Serialization carries Reference indices, never owner objects.
    public static func reader<Owner: AnyObject & Sendable>(
        of owner: Owner, read: @escaping @Sendable (Owner) async throws -> UIStateSnapshot
    ) -> Reader {
        { [weak owner] in
            try Task.checkCancellation()
            guard let owner else { throw ReadError.ownerReleased }
            return try await read(owner)
        }
    }
    public indirect enum Value: Codable, Sendable, Equatable {
        case text(String)
        case flag(Bool)
        case count(Int)
        case unsigned(UInt64)
        case number(Double)
        case integers([Int])
        case texts([String])
        case object([String: Value])
        case array([Value])
        case unknown
        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() {
                self = .unknown
            } else if let flag = try? value.decode(Bool.self) {
                self = .flag(flag)
            } else if let count = try? value.decode(Int.self) {
                self = .count(count)
            } else if let unsigned = try? value.decode(UInt64.self) {
                self = .unsigned(unsigned)
            } else if let number = try? value.decode(Double.self) {
                self = .number(number)
            } else if let integers = try? value.decode([Int].self) {
                self = .integers(integers)
            } else if let texts = try? value.decode([String].self) {
                self = .texts(texts)
            } else if let object = try? value.decode([String: Value].self) {
                self = .object(object)
            } else if let array = try? value.decode([Value].self) {
                self = .array(array)
            } else {
                self = .text(try value.decode(String.self))
            }
        }
        public func encode(to encoder: any Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .text(let item): try value.encode(item)
            case .flag(let item): try value.encode(item)
            case .count(let item): try value.encode(item)
            case .unsigned(let item): try value.encode(item)
            case .number(let item): try value.encode(item)
            case .integers(let item): try value.encode(item)
            case .texts(let item): try value.encode(item)
            case .object(let item): try value.encode(item)
            case .array(let item): try value.encode(item)
            case .unknown: try value.encodeNil()
            }
        }
    }
    public enum Health: String, Codable, Sendable { case healthy, limited, fault, unknown }
    public struct Issue: Codable, Sendable {
        public let code: String
        public let impact: String
        public init(code: String, impact: String) {
            self.code = code
            self.impact = impact
        }
    }
    public struct Descriptor: Codable, Sendable {
        public let path: String
        public let business: [String]
        public let runtime: [String]
        public let children: [Reference]
        public let meanings: [String: String]
        public let units: [String: String]
        public let stateValues: [String: [String]]
    }
    public let path: String
    public let business: [String: Value]
    public let runtime: [String: Value]
    public let health: Health
    public let issues: [Issue]
    public let children: [Reference]
    /// Collection time only; measurement age belongs to the owning business fact.
    public let collectedAt: Date
    public let meanings: [String: String]
    public let units: [String: String]
    public let stateValues: [String: [String]]
    public var stateDescriptor: Descriptor {
        Descriptor(
            path: path, business: business.keys.sorted(), runtime: runtime.keys.sorted(),
            children: children, meanings: meanings, units: units,
            stateValues: stateValues.merging(["health": ["healthy", "limited", "fault", "unknown"]]) { current, _ in
                current
            })
    }
    public init(
        path: String, business: [String: Value] = [:], runtime: [String: Value] = [:],
        health: Health = .unknown, issues: [Issue] = [], children: [Reference] = [],
        meanings: [String: String] = [:], units: [String: String] = [:], stateValues: [String: [String]] = [:]
    ) {
        self.path = path
        self.meanings = meanings
        self.units = units
        self.stateValues = stateValues
        self.business = business
        self.runtime = runtime
        self.health = health
        self.issues = issues
        self.children = children
        collectedAt = Date()
    }
}
