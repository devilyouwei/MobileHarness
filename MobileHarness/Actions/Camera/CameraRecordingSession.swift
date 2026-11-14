import Foundation
import FunctionContracts
import PlatformKit
import StorageCore
import StorageMedia
import UI

/// One recording and one pending clip, owned independently of window rendering.
@MainActor final class CameraRecordingSession {
    private let camera: any CameraCapturing
    private let inspect: @Sendable (URL) async throws -> NativeMovieInfo
    private let photos: MediaStore
    private let presentation: any CameraPresenting
    private let foreground: @MainActor () -> Bool
    private let acquireAudio: @MainActor () async throws -> Void
    private let releaseAudio: @MainActor (Bool) async throws -> Void
    private let activity: @MainActor (String?) -> Void
    private var startTask: Task<CameraVideoReceipt, any Error>?
    private var completion: Task<CameraVideoReceipt, any Error>?
    private var nativeID: String?
    private var audioHeld = false
    private var mayResumeAudio = true
    func invalidateForeground() { mayResumeAudio = false }
    private var mutating = false
    private struct Clip {
        let id: String
        let movie: CameraMovie
        let owner: StorageOwner
        var info: NativeMovieInfo?
        var mediaID: String?
    }
    private var clip: Clip?
    private var saved: CameraVideoReceipt?
    var busy: Bool { startTask != nil || mutating || presentation.snapshot.recording.active }
    var changing: Bool { startTask != nil || mutating || presentation.snapshot.recording.phase == .finishing }
    var hasClip: Bool { clip != nil }
    var id: String? { clip?.id ?? nativeID }
    init(
        camera: any CameraCapturing, photos: MediaStore, presentation: any CameraPresenting,
        foreground: @escaping @MainActor () -> Bool,
        acquireAudio: @escaping @MainActor () async throws -> Void,
        releaseAudio: @escaping @MainActor (Bool) async throws -> Void,
        activity: @escaping @MainActor (String?) -> Void,
        inspect: @escaping @Sendable (URL) async throws -> NativeMovieInfo = NativeAlbumMovie.inspect
    ) {
        self.inspect = inspect
        self.camera = camera
        self.photos = photos
        self.presentation = presentation
        self.foreground = foreground
        self.acquireAudio = acquireAudio
        self.releaseAudio = releaseAudio
        self.activity = activity
    }
    private func phase(_ phase: CameraRecordingPresentation.Phase, id: String? = nil) {
        var value = presentation.snapshot.recording
        value.phase = phase
        if let id { value.id = id }
        if phase == .recording { value.startedAt = Date() }
        if phase == .idle { value = .init() }
        presentation.present(.recording(value))
        activity(phase == .recording ? "Recording" : phase == .finishing ? "Finalizing" : nil)
    }
    func start(duration: Int, invocation: any FunctionInput) async throws -> CameraVideoReceipt {
        guard (1...600).contains(duration) else {
            throw ActionArguments.ValidationError.invalidValue("durationSeconds")
        }
        guard foreground() else { throw CameraControlError.notForeground }
        guard !busy, clip == nil else { throw CameraControlError.busy }
        mayResumeAudio = true
        phase(.idle)
        phase(.starting)
        presentation.present(.message(nil))
        presentation.present(.photoMessage(nil))
        var display = presentation.snapshot.recording
        display.durationLimit = duration
        presentation.present(.recording(display))
        let owner = StorageOwner(
            namespace: "photos", source: invocation.context.source,
            session: invocation.context.sessionID, input: invocation.context.inputID)
        let task = Task<CameraVideoReceipt, any Error> {
            do {
                let current = presentation.snapshot.settings
                if current.mode != "video" || current.flash != "off" || current.durationSeconds != duration {
                    try await CameraCaptureConfiguration.apply(
                        .init(
                            mode: "video", delaySeconds: current.delaySeconds, flash: "off", zoom: current.zoom,
                            durationSeconds: duration), camera: camera, presentation: presentation)
                }
                try Task.checkCancellation()
                guard foreground() else { throw CameraControlError.notForeground }
                audioHeld = true
                try await acquireAudio()
                try Task.checkCancellation()
                guard foreground() else { throw CameraControlError.notForeground }
                let rotation = try await presentation.waitForPhotoCaptureRotation()
                try Task.checkCancellation()
                guard foreground() else { throw CameraControlError.notForeground }
                let id = try await camera.beginRecording(durationSeconds: duration, rotation: CGFloat(rotation))
                nativeID = id
                phase(.recording, id: id)
                completion = Task { try await finish(id: id, owner: owner) }
                if Task.isCancelled {
                    _ = try? await camera.stopRecording(id)
                    _ = await completion?.result
                    throw CancellationError()
                }
                return CameraVideoReceipt(recordingID: id, state: "recording")
            } catch {
                phase(.failed)
                presentation.present(
                    .message(recordingMessage(error, fallback: "Could not start recording. Try again.")))
                let original = error
                do { try await returnAudio() } catch {
                    throw CameraRecordingCleanupFailure(primary: original, cleanup: error)
                }
                throw original
            }
        }
        startTask = task
        defer { startTask = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    private func returnAudio() async throws {
        guard audioHeld else { return }
        audioHeld = false
        try await releaseAudio(mayResumeAudio && foreground())
    }
    private func finish(id: String, owner: StorageOwner) async throws -> CameraVideoReceipt {
        do {
            let movie = try await camera.waitForRecording(id)
            nativeID = nil
            clip = Clip(id: id, movie: movie, owner: owner)
            phase(.finishing, id: id)
            let receipt = try await prepareClip()
            try await returnAudio()
            return receipt
        } catch {
            nativeID = nil
            phase(.failed, id: id)
            presentation.present(.message(recordingMessage(error, fallback: "Could not finish recording.")))
            let original = error
            do { try await returnAudio() } catch {
                throw CameraRecordingCleanupFailure(primary: original, cleanup: error)
            }
            throw original
        }
    }
    private func prepareClip() async throws -> CameraVideoReceipt {
        guard var selected = clip else { throw CameraControlError.unavailable }
        let info: NativeMovieInfo
        if let existing = selected.info { info = existing } else { info = try await inspect(selected.movie.file) }
        selected.info = info
        clip = selected
        if selected.mediaID == nil {
            selected.mediaID = try await photos.saveVideo(
                selected.movie.file, owner: selected.owner,
                metadata: .init(
                    mime: "video/quicktime", width: info.width, height: info.height, capturedAt: Date(),
                    origin: "camera"))
            clip = selected
        }
        guard let mediaID = selected.mediaID else { throw CameraControlError.unavailable }
        let file = try await photos.videoURL(mediaID, owner: selected.owner)
        presentation.present(.recordedVideo(.init(id: selected.id, file: file, duration: info.duration)))
        phase(.ready, id: selected.id)
        presentation.present(
            .message(
                selected.movie.stopReason == "sizeLimit"
                    ? "The recording reached the file size limit. Save or discard it." : nil))
        return CameraVideoReceipt(
            recordingID: selected.id, state: "ready", mediaID: mediaID,
            durationSeconds: info.duration, stopReason: selected.movie.stopReason, fileName: file.lastPathComponent)
    }
    /// Joins the existing session without owning a UI request slot. Cancellation stops only this recording.
    func wait(_ id: String) async throws -> CameraVideoReceipt {
        guard self.id == id || presentation.snapshot.recording.id == id, let completion else {
            throw CameraControlError.unavailable
        }
        let cancellation = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let stopper = Task {
            for await _ in cancellation.stream {
                guard nativeID == id else { return }
                // Native finish can win this race; the joined completion is the authoritative outcome.
                _ = try? await camera.stopRecording(id)
            }
        }
        let result = await withTaskCancellationHandler {
            await completion.result
        } onCancel: {
            cancellation.continuation.yield(())
        }
        cancellation.continuation.finish()
        await stopper.value
        let receipt = try result.get()
        try Task.checkCancellation()
        return receipt
    }
    func stop(_ id: String) async throws -> CameraVideoReceipt {
        guard self.id == id || presentation.snapshot.recording.id == id, let completion else {
            throw CameraControlError.unavailable
        }
        if let nativeID {
            phase(.finishing)
            // The completion owner may win the native-finish race; its actual result remains authoritative.
            do { _ = try await camera.stopRecording(nativeID) } catch { return try await completion.value }
        }
        return try await completion.value
    }
    func background() async {
        startTask?.cancel()
        _ = await startTask?.result
        if let nativeID { _ = try? await camera.stopRecording(nativeID) }
        _ = await completion?.result
    }
    func save(_ id: String) async throws -> CameraVideoReceipt {
        if let saved, saved.recordingID == id { return saved }
        guard !busy, clip?.id == id else { throw CameraControlError.busy }
        mutating = true
        defer { mutating = false }
        let prepared = try await prepareClip()
        guard let selected = clip, let mediaID = selected.mediaID else { throw CameraControlError.unavailable }
        // The durable pending copy already exists. Remove the source before the irreversible album commit.
        try removeTemporary(selected.movie.file)
        try await photos.collectVideo(mediaID, owner: selected.owner)
        let receipt = CameraVideoReceipt(
            recordingID: id, state: "saved", mediaID: mediaID,
            durationSeconds: prepared.durationSeconds, stopReason: prepared.stopReason, fileName: prepared.fileName)
        saved = receipt
        clip = nil
        presentation.present(.recordedVideo(nil))
        phase(.idle)
        presentation.present(.photoMessage("Video saved in the app album."))
        return receipt
    }
    func ignore(_ id: String) async throws -> CameraVideoReceipt {
        guard !busy, let selected = clip, selected.id == id else { throw CameraControlError.busy }
        mutating = true
        defer { mutating = false }
        if let mediaID = selected.mediaID { try await photos.discardVideo(mediaID, owner: selected.owner) }
        try removeTemporary(selected.movie.file)
        clip = nil
        presentation.present(.recordedVideo(nil))
        phase(.idle)
        return CameraVideoReceipt(recordingID: id, state: "ignored")
    }
    private func recordingMessage(_ error: any Error, fallback: String) -> String {
        if let native = error as? PlatformError {
            switch native {
            case .busy: return "The microphone is in use. Stop other audio operations and try again."
            case .unavailable, .stopped: return "Camera or audio session unavailable. Open the camera again."
            }
        }
        if error as? CameraError == .permissionDenied {
            return "Allow camera and microphone access in System Settings."
        }
        return fallback
    }
    private func removeTemporary(_ file: URL) throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

private struct CameraRecordingCleanupFailure: Error, LocalizedError {
    let primary: any Error
    let cleanup: any Error
    var errorDescription: String? { primary.localizedDescription + "; cleanup failed: " + cleanup.localizedDescription }
}

/// Shared native configuration transaction for explicit settings and recording preparation.
@MainActor enum CameraCaptureConfiguration {
    static func preparePhoto(camera: any CameraCapturing, presentation: any CameraPresenting) async throws {
        let current = presentation.snapshot.settings
        guard current.mode != "photo" else { return }
        try await apply(
            .init(
                mode: "photo", delaySeconds: current.delaySeconds, flash: current.flash,
                zoom: current.zoom, durationSeconds: current.durationSeconds),
            camera: camera, presentation: presentation)
    }
    static func applyUpdate(
        _ update: CameraCaptureSettings.Update, camera: any CameraCapturing, presentation: any CameraPresenting
    ) async throws {
        let current = presentation.snapshot.settings
        try await apply(
            .init(
                mode: update.mode ?? current.mode, delaySeconds: update.delaySeconds ?? current.delaySeconds,
                flash: update.flash ?? current.flash, zoom: update.zoom ?? current.zoom,
                durationSeconds: update.durationSeconds ?? current.durationSeconds),
            camera: camera, presentation: presentation)
    }
    static func apply(
        _ settings: CameraCaptureSettings, camera: any CameraCapturing, presentation: any CameraPresenting
    ) async throws {
        try settings.validate()
        try Task.checkCancellation()
        let previous = presentation.snapshot.settings
        let configured: CameraPhotoConfiguration
        do {
            try await camera.setVideoMode(settings.mode == "video")
            try Task.checkCancellation()
            configured = try await camera.configurePhoto(
                flash: CameraFlash(rawValue: settings.flash) ?? .off, zoom: settings.zoom)
            try Task.checkCancellation()
        } catch {
            let original = error
            // Configuration can partially commit. Join rollback with an uncancelled owner.
            let cleanup = Task {
                try await camera.setVideoMode(previous.mode == "video")
                _ = try await camera.configurePhoto(
                    flash: CameraFlash(rawValue: previous.flash) ?? .off, zoom: previous.zoom)
            }
            do { try await cleanup.value } catch {
                presentation.present(.message("Could not restore capture settings."))
                throw NativeCleanupFailure(errors: [original, error])
            }
            throw original
        }
        var display = CameraSettings()
        display.mode = settings.mode
        display.delaySeconds = settings.delaySeconds
        display.flash = configured.flash.rawValue
        display.zoom = configured.zoom
        display.durationSeconds = settings.durationSeconds
        display.maximumZoom = configured.maximumZoom
        display.supportedFlash = configured.supportedFlash.map(\.rawValue)
        presentation.present(.settings(display))
    }
}
