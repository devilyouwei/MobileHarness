import CoreGraphics
import Foundation
import Observation

public enum CameraDirection: Sendable { case front, back }

@MainActor
@Observable
public final class CameraState {
    @ObservationIgnored var presentationAdmission: UIPresentationAdmission?
    public var isPresentationAvailable: Bool { presentationAdmission.map { $0.started && !$0.stopped } ?? true }
    #if os(iOS)
        public internal(set) var capturedPhoto: CapturedPhotoPresentation?
    #endif
    public internal(set) var photoBusy = false
    public internal(set) var photoMessage: String?
    public internal(set) var savedMediaID: String?
    public internal(set) var isEnabled = false
    public internal(set) var facing: CameraDirection = .front
    public internal(set) var isVisible = false
    public internal(set) var isBusy = false
    public internal(set) var controlBusy = false
    public internal(set) var controlMessage: String?
    public internal(set) var message: String?
    public internal(set) var needsSettings = false
    public var canSwitchCamera: Bool {
        (presentationAdmission?.active ?? true) && isEnabled && isVisible
            && !isBusy && !controlBusy && !photoBusy && !needsSettings
    }
    public private(set) var rendererFailure: String?
    public private(set) var videoGeneration: UInt64 = 0
    public private(set) var videoFrame: CameraVideoFrame?
    @ObservationIgnored private let frameExpiry = CameraMediaExpiry()
    @ObservationIgnored private let poseExpiry = CameraMediaExpiry()
    private var lastPoseSequence: UInt64?
    private var lastFrameSequence: UInt64?
    public func presentRendererFailure(_ message: String, generation: UInt64) {
        guard presentationAdmission?.stopped != true, generation == videoGeneration else { return }
        let failure = UIFailure(
            component: "camera.renderer", operation: "render", underlying: CameraRendererFailure(message: message))
        onFailure(failure.component, failure.operation, failure)
        rendererFailure = message
        clearFrame()
        visionMessage = message
    }
    public func presentVideo(_ frame: CameraVideoFrame) throws {
        try presentationAdmission?.requireLive()
        guard rendererFailure == nil else { throw CameraFramePresentationError.unavailable }
        try validate(frame)
        if let previous = lastFrameSequence, frame.sequence <= previous { throw CameraFramePresentationError.stale }
        if let previous = videoFrame,
            previous.rotation != frame.rotation || previous.width != frame.width || previous.height != frame.height
        {
            clearPose()
        }
        lastFrameSequence = frame.sequence
        videoFrame = frame
        frameExpiry.update(frame.capturedAt.advanced(by: .milliseconds(750))) { [weak self] in
            self?.clearFrame()
        }
    }
    private func validate(_ frame: CameraVideoFrame) throws {
        guard (1...4096).contains(frame.width), (1...4096).contains(frame.height),
            frame.width * frame.height <= 4_194_304,
            frame.capturedAt.duration(to: .now) >= .zero,
            frame.capturedAt.duration(to: .now) < .milliseconds(750)
        else { throw CameraFramePresentationError.stale }
    }
    /// Pose admission never replaces or clears the independent camera image.
    public func present(frame: CameraVideoFrame, pose: PoseOverlay) throws {
        try presentationAdmission?.requireLive()
        try validate(frame)
        guard frame.sequence == pose.sequence, frame.rotation == pose.rotation,
            lastPoseSequence.map({ pose.sequence > $0 }) ?? true
        else { throw CameraFramePresentationError.stale }
        if let videoFrame {
            guard frame.rotation == videoFrame.rotation, frame.width == videoFrame.width,
                frame.height == videoFrame.height
            else { throw CameraFramePresentationError.stale }
        }
        lastPoseSequence = pose.sequence
        skeleton = pose
        poseExpiry.update(frame.capturedAt.advanced(by: .milliseconds(750))) { [weak self] in
            self?.clearPose()
        }
    }
    func clearPose() {
        poseExpiry.cancel()
        skeleton = nil
    }
    public func clearFrame() {
        frameExpiry.cancel()
        videoFrame = nil
        clearPose()
    }
    public private(set) var skeleton: PoseOverlay?
    /// Cancels and joins display timers; this does not acknowledge GPU completion.
    func stopPresentation() async {
        present(.isVisible(false))
        await frameExpiry.stop()
        await poseExpiry.stop()
    }
    public internal(set) var gaze: CGSize = .zero
    public internal(set) var visionMessage: String?
    @ObservationIgnored private var onFactsChanged: (@MainActor () -> Void)?
    private let onFailure: UIFailureReporting
    public init(onFailure: @escaping UIFailureReporting = { _, _, _ in }) { self.onFailure = onFailure }
    public func connectFactsObserver(_ observer: @escaping @MainActor () -> Void) { onFactsChanged = observer }
    /// Public presentation submission; this never grants native capture or motion authority.
    public func present(_ update: CameraPresentationUpdate) {
        defer {
            switch update {
            case .gaze, .visionMessage, .photoMessage, .controlBusy, .controlMessage: break
            default: onFactsChanged?()
            }
        }
        switch update {
        case .photoBusy(let value): photoBusy = value
        case .photoMessage(let value): photoMessage = value
        case .savedMediaID(let value): savedMediaID = value
        case .isEnabled(let value): isEnabled = value
        case .facing(let value): facing = value
        case .isVisible(let value):
            isVisible = value
            if !value {
                videoGeneration &+= 1
                rendererFailure = nil
                lastFrameSequence = nil
                lastPoseSequence = nil
                clearFrame()
            }
        case .isBusy(let value): isBusy = value
        case .controlBusy(let value): controlBusy = value
        case .controlMessage(let value): controlMessage = value
        case .message(let value): message = value
        case .needsSettings(let value): needsSettings = value
        case .gaze(let value): gaze = value
        case .visionMessage(let value):
            visionMessage = rendererFailure ?? value
            if value != nil { clearPose() }
        #if os(iOS)
            case .capturedPhoto(let value): capturedPhoto = value
        #endif
        }
    }

}

/// User controls only; capture, permission and inference lifetimes belong to module services.
@MainActor
public protocol CameraControlling: AnyObject {
    func toggle()
    func switchCamera()
    func retry()
    func savePhoto(_ id: String)
    func ignorePhoto(_ id: String)
}

public enum CameraPresentationUpdate {
    case photoBusy(Bool)
    case photoMessage(String?)
    case savedMediaID(String?)
    case isEnabled(Bool)
    case facing(CameraDirection)
    case isVisible(Bool)
    case isBusy(Bool)
    case controlBusy(Bool)
    case controlMessage(String?)
    case message(String?)
    case needsSettings(Bool)
    case gaze(CGSize)
    case visionMessage(String?)
    #if os(iOS)
        case capturedPhoto(CapturedPhotoPresentation?)
    #endif
}

public enum CameraFramePresentationError: Error { case stale, unavailable }

private struct CameraRendererFailure: Error, Sendable { let message: String }

/// One sleeping worker per media stream. Extending freshness only updates the deadline.
@MainActor
private final class CameraMediaExpiry {
    private var deadline: ContinuousClock.Instant?
    private var wake: ContinuousClock.Instant?
    private var revision: UInt64 = 0
    private var task: Task<Void, Never>?

    func update(_ deadline: ContinuousClock.Instant, expired: @escaping @MainActor () -> Void) {
        self.deadline = deadline
        if let wake, wake <= deadline { return }
        let previous = task
        previous?.cancel()
        revision &+= 1
        let revision = revision
        wake = deadline
        task = Task { [weak self] in
            await previous?.value
            while let next = self?.nextDeadline(revision: revision) {
                do { try await Task.sleep(until: next, clock: .continuous) } catch { return }
                guard !Task.isCancelled else { return }
                if self?.takeExpiry(revision: revision) == true {
                    expired()
                    return
                }
            }
        }
    }
    private func nextDeadline(revision: UInt64) -> ContinuousClock.Instant? {
        guard self.revision == revision else { return nil }
        wake = deadline
        return deadline
    }
    private func takeExpiry(revision: UInt64) -> Bool {
        guard self.revision == revision, let deadline, deadline <= .now else { return false }
        self.deadline = nil
        wake = nil
        return true
    }
    func cancel() {
        revision &+= 1
        deadline = nil
        wake = nil
        task?.cancel()
    }
    func stop() async {
        cancel()
        let previous = task
        let revision = revision
        await previous?.value
        // A replacement admitted while suspended must keep its join handle.
        if self.revision == revision { task = nil }
    }
    deinit { task?.cancel() }
}
