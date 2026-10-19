import CoreGraphics
import Foundation
import Observation

/// One renderer request. The host owns the operation and releases the image after acknowledgment.
@MainActor
@Observable
public final class PhotoDeparture {
    public enum Kind: String, Sendable { case save, discard }
    public struct Request: Equatable, Sendable {
        public let id: String
        public let kind: Kind
    }
    public enum Failure: Error, Sendable { case rendererUnavailable, busy }
    public private(set) var request: Request?
    private var available = false
    private var finished = false
    private var waiter: CheckedContinuation<Void, any Error>?
    public init() {}
    public func setAvailable(_ value: Bool) {
        available = value
        if !value, let request { complete(id: request.id, success: false) }
    }
    public func perform(_ kind: Kind) async throws {
        try Task.checkCancellation()
        guard available else { throw Failure.rendererUnavailable }
        guard request == nil, !finished else { throw Failure.busy }
        let id = UUID().uuidString
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiter = continuation
                request = Request(id: id, kind: kind)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }
    public func complete(id: String, success: Bool) {
        guard request?.id == id else { return }
        finish(success ? .success(()) : .failure(Failure.rendererUnavailable))
    }
    private func cancel(id: String) {
        guard request?.id == id else { return }
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<Void, any Error>) {
        let pending = waiter
        waiter = nil
        request = nil
        finished = true
        pending?.resume(with: result)
    }
}

public enum PhotoDeparturePhase: Sendable { case resting, enlarged, exited }
public struct PhotoDepartureLayout: Equatable, Sendable {
    public let center: CGPoint
    public let scale: Double
    public static func pose(
        size: CGSize, bottomInset: CGFloat, kind: PhotoDeparture.Kind?, phase: PhotoDeparturePhase
    ) -> Self {
        let origin = CGPoint(x: max(48, size.width - 68), y: max(64, size.height - bottomInset - 84))
        switch (kind, phase) {
        case (.save, .enlarged): return Self(center: origin, scale: 1.16)
        case (.save, .exited): return Self(center: CGPoint(x: size.width + 112, y: origin.y), scale: 1.16)
        case (.discard, .exited):
            return Self(center: CGPoint(x: size.width + 24, y: size.height + 24), scale: 0.06)
        default: return Self(center: origin, scale: 1)
        }
    }
}
