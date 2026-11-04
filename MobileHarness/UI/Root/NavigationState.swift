import Foundation
import Observation

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
    case settings, language, recognition, synthesis, vision, bluetooth, assistantHistory, writerHistory, album
}
@MainActor
@Observable
public final class NavigationState {
    @ObservationIgnored var presentationAdmission: UIPresentationAdmission?
    @ObservationIgnored var onHomeVisibilityChanged: ((Bool) -> Void)?
    public var isPresentationAvailable: Bool { presentationAdmission.map { $0.started && !$0.stopped } ?? true }

    public internal(set) var path: [AppDestination] = [] {
        didSet {
            generation = UUID()
            phase = .transitioning
            overlay = nil
            content = .idle
            if oldValue.isEmpty != path.isEmpty { onHomeVisibilityChanged?(path.isEmpty) }
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
            || (["assistantHistory", "writerHistory"].contains(destination)
                && [.agentRecords, .conversation, .turn].contains(location.page))
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
