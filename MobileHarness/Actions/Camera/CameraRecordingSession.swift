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
    private let photos: CapturedPhotoStore
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
        camera: any CameraCapturing, photos: CapturedPhotoStore, presentation: any CameraPresenting,
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
        activity(phase == .recording ? "录制中" : phase == .finishing ? "正在收尾" : nil)
    }
    func start(duration: Int, invocation: any FunctionInput) async throws -> CameraVideoReceipt {
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
                audioHeld = true
                try await acquireAudio()
                try Task.checkCancellation()
                guard foreground() else { throw CameraControlError.notForeground }
                guard let rotation = presentation.snapshot.photoCaptureRotation else {
                    throw CameraControlError.unavailable
                }
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
                presentation.present(.message("录像启动失败：" + recordingMessage(error)))
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
            try await returnAudio()
            return try await prepareClip()
        } catch {
            nativeID = nil
            phase(.failed, id: id)
            presentation.present(.message("录像收尾失败：" + recordingMessage(error)))
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
        presentation.present(.message(selected.movie.stopReason == "sizeLimit" ? "录像已达到文件大小上限，请保存或忽略" : nil))
        return CameraVideoReceipt(
            recordingID: selected.id, state: "ready", mediaID: mediaID,
            durationSeconds: info.duration, stopReason: selected.movie.stopReason)
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
            durationSeconds: prepared.durationSeconds, stopReason: prepared.stopReason)
        saved = receipt
        clip = nil
        presentation.present(.recordedVideo(nil))
        phase(.idle)
        presentation.present(.photoMessage("视频已保存到 App 相册"))
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
    private func recordingMessage(_ error: any Error) -> String {
        if let native = error as? PlatformError {
            switch native {
            case .busy: return "麦克风被其他音频操作占用，请结束后重试"
            case .unavailable, .stopped: return "相机或音频会话暂不可用，请重新开启"
            }
        }
        if error as? CameraError == .permissionDenied { return "请在系统设置中允许相机和麦克风权限" }
        return error.localizedDescription
    }
    private func removeTemporary(_ file: URL) throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

private struct CameraRecordingCleanupFailure: Error, LocalizedError {
    let primary: any Error
    let cleanup: any Error
    var errorDescription: String? { primary.localizedDescription + "；清理失败：" + cleanup.localizedDescription }
}
