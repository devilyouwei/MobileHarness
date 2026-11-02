import Foundation

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
