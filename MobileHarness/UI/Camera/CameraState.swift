import CoreGraphics
import Foundation
import Observation

public enum CameraDirection: Sendable { case front, back }

@MainActor @Observable
public final class CameraState {
    #if os(iOS)
        public var capturedPhoto: CapturedPhotoPresentation?
    #endif
    public var photoBusy = false
    public var photoMessage: String?
    public var savedMediaID: String?
    public var isEnabled = false
    public var facing: CameraDirection = .front
    public var isVisible = false
    public var isBusy = false
    public var message: String?
    public var needsSettings = false
    public private(set) var rendererFailure: String?
    public private(set) var videoGeneration: UInt64 = 0
    public private(set) var videoFrame: CameraVideoFrame?
    @ObservationIgnored private var frameExpiry: Task<Void, Never>?
    @ObservationIgnored private var poseExpiry: Task<Void, Never>?
    private var poseRevision: UInt64 = 0
    private var lastPoseSequence: UInt64?
    private var frameRevision: UInt64 = 0
    private var lastFrameSequence: UInt64?
    public func presentRendererFailure(_ message: String, generation: UInt64) {
        guard generation == videoGeneration else { return }
        rendererFailure = message
        clearFrame()
        visionMessage = message
    }
    public func presentVideo(_ frame: CameraVideoFrame) throws {
        guard rendererFailure == nil else { throw CameraFramePresentationError.unavailable }
        try validate(frame)
        if let previous = lastFrameSequence, frame.sequence <= previous { throw CameraFramePresentationError.stale }
        if let previous = videoFrame,
            previous.rotation != frame.rotation || previous.width != frame.width || previous.height != frame.height
        {
            clearPose()
        }
        frameRevision &+= 1
        let revision = frameRevision
        let previousExpiry = frameExpiry
        previousExpiry?.cancel()
        lastFrameSequence = frame.sequence
        videoFrame = frame
        frameExpiry = Task { [weak self] in
            await previousExpiry?.value
            do {
                try await Task.sleep(until: frame.capturedAt.advanced(by: .milliseconds(750)), clock: .continuous)
            } catch { return }
            guard let self, self.frameRevision == revision else { return }
            self.clearFrame()
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
        try validate(frame)
        guard frame.sequence == pose.sequence, frame.rotation == pose.rotation,
            lastPoseSequence.map({ pose.sequence > $0 }) ?? true
        else { throw CameraFramePresentationError.stale }
        if let videoFrame {
            guard frame.rotation == videoFrame.rotation, frame.width == videoFrame.width,
                frame.height == videoFrame.height
            else { throw CameraFramePresentationError.stale }
        }
        poseRevision &+= 1
        let revision = poseRevision
        let previousExpiry = poseExpiry
        previousExpiry?.cancel()
        lastPoseSequence = pose.sequence
        skeleton = pose
        poseExpiry = Task { [weak self] in
            await previousExpiry?.value
            do {
                try await Task.sleep(until: frame.capturedAt.advanced(by: .milliseconds(750)), clock: .continuous)
            } catch { return }
            guard let self, self.poseRevision == revision else { return }
            self.clearPose()
        }
    }
    func clearPose() {
        poseRevision &+= 1
        poseExpiry?.cancel()
        skeleton = nil
    }
    public func clearFrame() {
        frameRevision &+= 1
        frameExpiry?.cancel()
        videoFrame = nil
        clearPose()
    }
    public private(set) var skeleton: PoseOverlay?
    /// Cancels and joins display timers; this does not acknowledge GPU completion.
    func stopPresentation() async {
        let frame = frameExpiry
        let pose = poseExpiry
        present(.isVisible(false))
        await frame?.value
        await pose?.value
        frameExpiry = nil
        poseExpiry = nil
    }
    public var gaze: CGSize = .zero
    public var visionMessage: String?
    @ObservationIgnored private var onFactsChanged: (@MainActor () -> Void)?
    public init() {}
    public func connectFactsObserver(_ observer: @escaping @MainActor () -> Void) { onFactsChanged = observer }
    /// Public presentation submission; this never grants native capture or motion authority.
    public func present(_ update: CameraPresentationUpdate) {
        defer {
            switch update {
            case .gaze, .visionMessage, .photoMessage: break
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
    case message(String?)
    case needsSettings(Bool)
    case gaze(CGSize)
    case visionMessage(String?)
    #if os(iOS)
        case capturedPhoto(CapturedPhotoPresentation?)
    #endif
}

public enum CameraFramePresentationError: Error { case stale, unavailable }
