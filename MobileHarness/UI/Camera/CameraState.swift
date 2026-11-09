import CoreGraphics
import Foundation
import Observation

public struct CameraRecordingPresentation: Sendable, Equatable {
    public enum Phase: String, Sendable { case idle, starting, recording, finishing, ready, failed }
    public var phase: Phase = .idle
    public var id: String?
    public var startedAt: Date?
    public var durationLimit = 600
    public var active: Bool { [.starting, .recording, .finishing].contains(phase) }
    public init() {}
}
public struct CameraRecordedVideo: Sendable, Equatable {
    public let id: String
    public let file: URL
    public let duration: Double
    public init(id: String, file: URL, duration: Double) {
        self.id = id
        self.file = file
        self.duration = duration
    }
}

public enum CameraSurface: String, Sendable { case capture, perception }

public struct CameraSettings: Sendable, Equatable {
    public var mode = "photo"
    public var delaySeconds = 0
    public var flash = "off"
    public var zoom = 1.0
    public var durationSeconds = 600
    public var maximumZoom = 1.0
    public var supportedFlash = ["off"]
    public init() {}
}

public enum CameraDirection: Sendable { case front, back }

@MainActor
@Observable
public final class CameraState {
    public internal(set) var gallerySession: String?
    public internal(set) var previews: [CameraPreviewItem] = []
    @ObservationIgnored var presentationAdmission: UIPresentationAdmission?
    public var isPresentationAvailable: Bool { presentationAdmission.map { $0.started && !$0.stopped } ?? true }
    #if os(iOS)
        public internal(set) var capturedPhoto: CapturedPhotoPresentation?
    #endif
    public internal(set) var recording = CameraRecordingPresentation()
    public internal(set) var recordedVideo: CameraRecordedVideo?
    public internal(set) var settings = CameraSettings()
    public internal(set) var countdown: Int?
    public internal(set) var photoBusy = false
    public internal(set) var photoMessage: String?
    public internal(set) var savedPreviewID: String?
    public internal(set) var savedMediaID: String?
    public internal(set) var isEnabled = false
    public internal(set) var perceptionEnabled = false
    public var faceVisible = false
    public weak var windows: WindowState?
    public internal(set) var lensHandoff = false
    public var lensOwner: CameraSurface? {
        guard isPresentationAvailable, !lensHandoff else { return nil }
        if let windows {
            guard windows.available, !windows.windows.contains(where: { !$0.presentationConfirmed }) else { return nil }
            if let item = windows.windows.first(where: { $0.content == WindowContent.camera.rawValue }),
                item.mode != .minimized, windows.hasVisibleContent(item.id, topInset: 52, bottomInset: 140)
            {
                return .capture
            }
            return perceptionEnabled && faceVisible && windows.hasVisibleBackground() ? .perception : nil
        }
        return isEnabled ? .capture : (perceptionEnabled && faceVisible ? .perception : nil)
    }
    public func canSwitch(_ surface: CameraSurface) -> Bool {
        (presentationAdmission?.active ?? true) && lensOwner == surface && isVisible
            && (surface == .capture ? isEnabled : perceptionEnabled)
            && !isBusy && !controlBusy && !photoBusy && !recording.active && !needsSettings
    }
    public internal(set) var facing: CameraDirection = .front
    public internal(set) var isVisible = false
    public internal(set) var isBusy = false
    public internal(set) var controlBusy = false
    public internal(set) var controlMessage: String?
    public internal(set) var message: String?
    public internal(set) var needsSettings = false
    public var canSwitchCamera: Bool {
        canSwitch(.capture)
    }
    public private(set) var rendererFailure: String?
    public private(set) var photoRendererFailure: String?
    public private(set) var videoGeneration: UInt64 = 0
    public private(set) var videoFrame: CameraVideoFrame?
    private(set) var interfaceOrientation = CameraInterfaceOrientation.portrait
    func presentInterfaceOrientation(_ orientation: CameraInterfaceOrientation, generation: UInt64) {
        guard presentationAdmission?.stopped != true, generation == videoGeneration else { return }
        interfaceOrientation = orientation
    }
    private var photoOrientation = CameraInterfaceOrientation.portrait
    func presentPhotoOrientation(_ orientation: CameraInterfaceOrientation, generation: UInt64) {
        guard presentationAdmission?.stopped != true, generation == videoGeneration else { return }
        photoOrientation = orientation
        if let frame = videoFrame { updatePhotoAspect(frame) }
    }
    /// Sensor-to-window angle of the current preview, frozen by the capture caller at shutter time.
    public var photoCaptureRotation: Double? {
        guard let videoFrame, (try? validate(videoFrame)) != nil, let previewBasis else { return nil }
        return Double(previewBasis.displayRotation(photoOrientation) * 90)
    }
    public private(set) var photoAspect: Double = 3.0 / 4.0
    private func updatePhotoAspect(_ frame: CameraVideoFrame) {
        let geometry = CameraPreviewGeometry(
            frame: frame, size: .init(width: 1, height: 1), orientation: photoOrientation)
        let aspect = geometry.imageSize.width / geometry.imageSize.height
        if photoAspect != aspect { photoAspect = aspect }
    }
    private(set) var previewBasis: CameraPreviewBasis?
    var displayGaze: CGSize {
        previewBasis?.gaze(gaze, orientation: interfaceOrientation, mirrored: facing == .front) ?? gaze
    }
    @ObservationIgnored private let frameExpiry = CameraMediaExpiry()
    @ObservationIgnored private let poseExpiry = CameraMediaExpiry()
    private var lastPoseSequence: UInt64?
    private var lastFrameSequence: UInt64?
    public func presentRendererFailure(_ message: String, generation: UInt64, surface: CameraSurface = .perception) {
        guard presentationAdmission?.stopped != true, generation == videoGeneration else { return }
        let failure = UIFailure(
            component: "camera.renderer", operation: "render", underlying: CameraRendererFailure(message: message))
        onFailure(failure.component, failure.operation, failure)
        defer { onFactsChanged?() }
        if surface == .capture {
            photoRendererFailure = message
        } else {
            rendererFailure = message
            visionMessage = message
        }
    }
    public func presentVideo(_ frame: CameraVideoFrame) throws {
        try presentationAdmission?.requireLive()
        try validate(frame)
        if let previous = lastFrameSequence, frame.sequence <= previous { throw CameraFramePresentationError.stale }
        if let previous = videoFrame,
            previous.rotation != frame.rotation || previous.width != frame.width || previous.height != frame.height
                || previous.portraitRotation != frame.portraitRotation
        {
            clearPose()
        }
        lastFrameSequence = frame.sequence
        let basis = CameraPreviewBasis(rotation: frame.rotation, portraitRotation: frame.portraitRotation)
        if previewBasis != basis { previewBasis = basis }
        updatePhotoAspect(frame)
        videoFrame = frame
        frameExpiry.update(frame.capturedAt.advanced(by: .milliseconds(750))) { [weak self] in
            self?.clearFrame()
        }
    }
    private func validate(_ frame: CameraVideoFrame) throws {
        guard (1...4096).contains(frame.width), (1...4096).contains(frame.height),
            frame.width * frame.height <= 4_194_304, (0...3).contains(frame.rotation),
            frame.portraitRotation.map({ (0...3).contains($0) }) ?? true,
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
                frame.height == videoFrame.height, frame.portraitRotation == videoFrame.portraitRotation
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
        previewBasis = nil
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
        case .recording(let value): recording = value
        case .recordedVideo(let value): recordedVideo = value
        case .settings(let value): settings = value
        case .gallery(let session, let items):
            gallerySession = session
            previews = items
        case .countdown(let value): countdown = value
        case .photoBusy(let value): photoBusy = value
        case .photoMessage(let value): photoMessage = value
        case .savedPreviewID(let value): savedPreviewID = value
        case .savedMediaID(let value): savedMediaID = value
        case .isEnabled(let value): isEnabled = value
        case .perceptionEnabled(let value): perceptionEnabled = value
        case .lensHandoff(let value): lensHandoff = value
        case .facing(let value): facing = value
        case .isVisible(let value):
            isVisible = value
            if !value {
                videoGeneration &+= 1
                rendererFailure = nil
                photoRendererFailure = nil
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
    func previewImage(_ id: String, session: String) async throws -> Data
    func startRecording()
    func stopRecording()
    func saveVideo(_ id: String)
    func ignoreVideo(_ id: String)
    func configure(_ settings: CameraSettings)
    func cancelCapture()
    func takePhoto()
    func open()
    func toggle()
    func switchCamera()
    func togglePerception()
    func retryPerception()
    func switchPerceptionCamera()
    func retry()
    func savePhoto(_ id: String)
}

public enum CameraPresentationUpdate {
    case gallery(String?, [CameraPreviewItem])
    case recording(CameraRecordingPresentation)
    case recordedVideo(CameraRecordedVideo?)
    case settings(CameraSettings)
    case countdown(Int?)
    case photoBusy(Bool)
    case photoMessage(String?)
    case savedPreviewID(String?)
    case savedMediaID(String?)
    case isEnabled(Bool)
    case perceptionEnabled(Bool)
    case lensHandoff(Bool)
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

extension CameraControlling {
    public func previewImage(_ id: String, session: String) async throws -> Data { throw UIRequestError.unavailable }
    public func startRecording() {}
    public func stopRecording() {}
    public func saveVideo(_ id: String) {}
    public func ignoreVideo(_ id: String) {}
    public func configure(_ settings: CameraSettings) {}
    public func cancelCapture() {}
    public func open() { retry() }
    public func togglePerception() {}
    public func retryPerception() {}
    public func switchPerceptionCamera() {}
}

public struct CameraPreviewItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let status: String
    public let mediaID: String?
    public init(id: String, status: String, mediaID: String? = nil) {
        self.id = id
        self.status = status
        self.mediaID = mediaID
    }
}

/// Stable gallery identity is independent of its changing FIFO position.
public enum CameraGalleryNavigation {
    public static let maximumZoom: CGFloat = 4
    public static func index(_ selected: String?, in ids: [String]) -> Int {
        selected.flatMap { ids.firstIndex(of: $0) } ?? max(0, ids.count - 1)
    }
    public static func retainedSelection(_ selected: String?, in ids: [String]) -> String? {
        guard let selected else { return nil }
        return ids.contains(selected) ? selected : ids.first
    }
    public static func moved(_ selected: String?, by delta: Int, in ids: [String]) -> String? {
        guard delta == -1 || delta == 1 else { return nil }
        let next = index(selected, in: ids) + delta
        return ids.indices.contains(next) ? ids[next] : nil
    }
}
