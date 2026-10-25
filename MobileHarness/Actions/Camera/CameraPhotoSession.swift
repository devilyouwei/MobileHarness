#if os(iOS)
    import FunctionContracts
    import ExecutionRuntime
    import Foundation
    import OSLog
    import PlatformKit
    import StorageCore
    import StorageMedia
    import UI
    import UIKit

    /// Owns one capture or disposition and its presentation/feedback cleanup, independently of camera capture.
    @MainActor final class CameraPhotoSession: UIFeedbackCapability {
        private let camera: any CameraCapturing
        private let presentation: any CameraPresenting
        private var state: CameraPresentationSnapshot { presentation.snapshot }
        private let photos: CapturedPhotoStore
        private let photoCues: any CuePlaying
        private let isForeground: @MainActor () -> Bool
        private let captureRevision: @MainActor () -> Int
        private let ensureCaptureAvailable: @MainActor () throws -> Void
        private var foreground: Bool { isForeground() }
        private var revision: Int { captureRevision() }
        private let log = Logger(subsystem: "dev.mobileharness", category: "CameraPhotos")
        private var photoTask: Task<CameraPhotoReceipt, Error>?
        private var photoCommand: Task<CameraPhotoCommandReceipt, Error>?
        private var photoOwner: (id: String, owner: StorageOwner)?
        private var presentationFinished: (id: String, success: Bool)?
        private var photoFeedbackContext: ActionExecutionContext?
        var isBusy: Bool { photoTask != nil || photoCommand != nil }
        init(
            camera: any CameraCapturing, presentation: any CameraPresenting, photos: CapturedPhotoStore,
            photoCues: any CuePlaying,
            isForeground: @escaping @MainActor () -> Bool, captureRevision: @escaping @MainActor () -> Int,
            ensureCaptureAvailable: @escaping @MainActor () throws -> Void
        ) {
            self.camera = camera
            self.presentation = presentation
            self.photos = photos
            self.photoCues = photoCues
            self.isForeground = isForeground
            self.captureRevision = captureRevision
            self.ensureCaptureAvailable = ensureCaptureAvailable
        }
        func cancel() {
            photoTask?.cancel()
            photoCommand?.cancel()
        }
        func stopAndWait() async {
            cancel()
            _ = await photoTask?.result
            _ = await photoCommand?.result
        }
        public func readPhoto(_ id: String, source: String, sessionID: String, inputID: String) async throws -> Data {
            try await photos.read(
                id, owner: StorageOwner(namespace: "photos", source: source, session: sessionID, input: inputID))
        }

        private func selectedPhoto(_ requested: String?) throws -> (id: String, owner: StorageOwner) {
            guard let selected = photoOwner, state.capturedPhoto?.id == selected.id,
                requested == nil || requested == selected.id,
                state.capturedPhoto?.didReachThumbnail == true
            else { throw CameraControlError.photoUnavailable }
            return selected
        }

        public func ignorePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt
        {
            try Task.checkCancellation()
            guard foreground else { throw CameraControlError.notForeground }
            guard photoTask == nil, photoCommand == nil else { throw CameraControlError.busy }
            let selected = try selectedPhoto(id)
            guard let photo = state.capturedPhoto else { throw CameraControlError.photoUnavailable }
            let task = Task<CameraPhotoCommandReceipt, Error> {
                let issues = try await departPhoto(photo, kind: .discard, invocation: invocation, commit: {})
                return CameraPhotoCommandReceipt(
                    mediaID: selected.id, state: .ignored, feedbackIssues: issues.isEmpty ? nil : issues)
            }
            photoCommand = task
            presentation.present(.photoBusy(true))
            defer {
                photoCommand = nil
                presentation.present(.photoBusy(false))
            }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }

        public func savePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt {
            try Task.checkCancellation()
            guard foreground else { throw CameraControlError.notForeground }
            guard photoTask == nil, photoCommand == nil else { throw CameraControlError.busy }
            if let id, state.savedMediaID == id {
                return CameraPhotoCommandReceipt(mediaID: id, state: .saved, alreadySaved: true)
            }
            let selected = try selectedPhoto(id)
            guard let photo = state.capturedPhoto else { throw CameraControlError.photoUnavailable }
            presentation.present(.photoBusy(true))
            presentation.present(.photoMessage("正在保存到 App 相册…"))
            let task = Task<CameraPhotoCommandReceipt, Error> {
                let issues = try await departPhoto(photo, kind: .save, invocation: invocation) { [self] in
                    let data = try await photos.read(selected.id, owner: selected.owner)
                    let info = try await NativeAlbumImage.inspect(data)
                    try Task.checkCancellation()
                    guard foreground, state.capturedPhoto?.id == selected.id else { throw CancellationError() }
                    try await photos.collect(
                        selected.id, owner: selected.owner,
                        metadata: PhotoMetadata(
                            mime: info.mime, width: info.width, height: info.height, capturedAt: info.capturedAt,
                            origin: "camera"))
                    // App album collection remains committed if subsequent feedback fails.
                    presentation.present(.savedMediaID(selected.id))
                    presentation.present(.photoMessage("已保存到 App 相册"))
                }
                return CameraPhotoCommandReceipt(
                    mediaID: selected.id, state: .saved, feedbackIssues: issues.isEmpty ? nil : issues)
            }
            photoCommand = task
            defer {
                photoCommand = nil
                presentation.present(.photoBusy(false))
            }
            do {
                return try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            } catch {
                presentation.present(
                    .photoMessage(
                        state.savedMediaID == selected.id
                            ? "已保存到 App 相册，退场反馈已中断" : "保存失败：" + error.localizedDescription))
                throw error
            }
        }

        private func departPhoto(
            _ photo: CapturedPhotoPresentation, kind: PhotoDeparture.Kind, invocation: any FunctionInput,
            commit: @escaping @MainActor @Sendable () async throws -> Void
        ) async throws -> [String] {
            let cue: UIActions.Cue = kind == .save ? .save : .discard
            photoFeedbackContext = invocation.context
            defer { photoFeedbackContext = nil }
            let issues = try await PhotoDispositionWorkflow.run(
                commit: commit,
                animation: { [presentation] in try await presentation.departPhoto(id: photo.id, kind: kind) },
                sound: { [self] in
                    guard
                        let definition = UIModule.feedbackDefinitions(feedback: self).first(where: {
                            $0.path.function == "playCue"
                        })
                    else { throw UIActions.FeedbackError.unavailable }
                    let child = FunctionInvocation(
                        call: FunctionRequest(
                            actionPath: definition.path, parameters: ["cue": cue.rawValue, "volume": "0.85"]),
                        context: invocation.context, executionID: UUID().uuidString,
                        results: ActionReportStore())
                    let completion = try await FunctionExecutor.perform(child, definition: definition)
                    if case .report(let report) = completion, report.hasFailures || report.isCancelled {
                        throw PhotoCueFailure(description: report.failureDescription ?? "Photo cue failed")
                    }
                },
                remove: { [self] in
                    guard state.capturedPhoto?.id == photo.id else { return }
                    presentation.present(.capturedPhoto(nil))
                    photoOwner = nil
                    presentation.present(.photoMessage(nil))
                })
            if !issues.isEmpty { log.error("照片已处理，退场反馈异常：\(issues.joined(separator: "; "), privacy: .public)") }
            return issues
        }
        private struct PhotoCueFailure: Error, Sendable { let description: String }
        public func playCue(_ request: UIActions.CueRequest, invocation: any FunctionInput) async throws {
            try Task.checkCancellation()
            guard foreground, photoCommand != nil, photoFeedbackContext == invocation.context,
                request.cue == .save || request.cue == .discard
            else { throw CancellationError() }
            let samples = try await Task.detached(priority: .userInitiated) { try FeedbackTone.samples(for: request) }
                .value
            try Task.checkCancellation()
            guard foreground, photoFeedbackContext == invocation.context else { throw CancellationError() }
            try await photoCues.play(PlaybackPCM(samples: samples, sampleRate: FeedbackTone.sampleRate))
        }
        public func vibrate(_ request: UIActions.HapticRequest, invocation: any FunctionInput) async throws {
            throw UIActions.FeedbackError.unavailable
        }

        public func takePhoto(invocation: any FunctionInput) async throws -> CameraPhotoReceipt {
            try Task.checkCancellation()
            guard foreground else { throw CameraControlError.notForeground }
            guard photoTask == nil, photoCommand == nil else { throw CameraControlError.busy }
            try ensureCaptureAvailable()
            let expectedRevision = revision
            let task = Task<CameraPhotoReceipt, Error> {
                let rotation = await camera.captureRotation
                let data = try await camera.capturePhoto(rotation: rotation)
                try Task.checkCancellation()
                guard foreground, state.isVisible, revision == expectedRevision else { throw CancellationError() }
                guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
                    throw CameraControlError.unavailable
                }
                let owner = StorageOwner(
                    namespace: "photos", source: invocation.context.source,
                    session: invocation.context.sessionID, input: invocation.context.inputID)
                let id = try await photos.save(data, owner: owner)
                // Durable capture is retained if subsequent presentation or turn delivery fails.
                let receipt = try CameraPhotoReceipt(
                    mediaID: id, width: Int(image.size.width * image.scale),
                    height: Int(image.size.height * image.scale))
                try Task.checkCancellation()
                guard foreground, revision == expectedRevision else { throw CancellationError() }
                presentationFinished = nil
                photoOwner = (id, owner)
                presentation.present(.savedMediaID(nil))
                presentation.present(.photoMessage(nil))
                try presentation.presentPhoto(id: id, image: image) { [weak self] success in
                    guard let self, self.state.capturedPhoto?.id == id else { return }
                    self.presentationFinished = (id, success)
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                do {
                    while presentationFinished?.id != id {
                        try Task.checkCancellation()
                        guard foreground, revision == expectedRevision else { throw CancellationError() }
                        guard ContinuousClock.now < deadline else { throw CameraPhotoDisplayFailure(mediaID: id) }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    guard presentationFinished?.success == true else { throw CameraPhotoDisplayFailure(mediaID: id) }
                    return receipt
                } catch {
                    if state.capturedPhoto?.id == id {
                        presentation.present(.capturedPhoto(nil))
                        photoOwner = nil
                    }
                    throw error
                }
            }
            photoTask = task
            presentation.present(.photoBusy(true))
            defer {
                photoTask = nil
                presentation.present(.photoBusy(false))
            }
            return try await withTaskCancellationHandler {
                let result = try await task.value
                try Task.checkCancellation()
                return result
            } onCancel: {
                task.cancel()
            }
        }

    }

    private struct CameraPhotoDisplayFailure: Error, LocalizedError, ActionExecutionFailureProviding {
        public let mediaID: String
        public var executionFailureCode: ActionExecutionFailureCode { .init(rawValue: "photoPresentationFailed") }
        public var errorDescription: String? { "Photo \(mediaID) was saved, but its presentation did not complete." }
    }

#endif
