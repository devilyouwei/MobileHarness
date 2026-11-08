import Foundation
import FunctionContracts

/// A monotonic countdown inside the caller's owned capture task; no independent timer or queued shutter.
@MainActor enum CameraCountdown {
    static func wait(
        seconds: Int, now: ContinuousClock.Instant = .now,
        publish: (Int?) -> Void,
        sleep: (ContinuousClock.Instant) async throws -> Void = { try await Task.sleep(until: $0, clock: .continuous) }
    ) async throws {
        defer { publish(nil) }
        guard (0...30).contains(seconds) else { throw CameraControlError.unavailable }
        try Task.checkCancellation()
        guard seconds > 0 else { return }
        let deadline = now.advanced(by: .seconds(seconds))
        for remaining in (1...seconds).reversed() {
            try Task.checkCancellation()
            publish(remaining)
            try await sleep(deadline.advanced(by: .seconds(1 - remaining)))
        }
        try Task.checkCancellation()
    }
}

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
        private let previews: CameraPreviewStore
        private let photoCues: any CuePlaying
        private let isForeground: @MainActor () -> Bool
        private let captureRevision: @MainActor () -> Int
        private let ensureCaptureAvailable: @MainActor () throws -> Void
        private var foreground: Bool { isForeground() }
        private var revision: Int { captureRevision() }
        private let log = Logger(subsystem: "dev.mobileharness", category: "CameraPhotos")
        private var photoTask: Task<CameraPhotoReceipt, Error>?
        private var photoCommand: Task<CameraPhotoCommandReceipt, Error>?
        private var presentationFinished: (id: String, success: Bool)?
        private var photoFeedbackContext: ActionExecutionContext?
        var isBusy: Bool { photoTask != nil || photoCommand != nil }
        init(
            camera: any CameraCapturing, presentation: any CameraPresenting, previews: CameraPreviewStore,
            photoCues: any CuePlaying,
            isForeground: @escaping @MainActor () -> Bool, captureRevision: @escaping @MainActor () -> Int,
            ensureCaptureAvailable: @escaping @MainActor () throws -> Void
        ) {
            self.camera = camera
            self.presentation = presentation
            self.previews = previews
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
        public func ignorePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt
        {
            try await dispose(id, save: false, invocation: invocation)
        }
        public func savePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt {
            try await dispose(id, save: true, invocation: invocation)
        }
        private func dispose(_ id: String?, save: Bool, invocation: any FunctionInput) async throws
            -> CameraPhotoCommandReceipt
        {
            try Task.checkCancellation()
            guard foreground else { throw CameraControlError.notForeground }
            guard photoTask == nil, photoCommand == nil else { throw CameraControlError.busy }
            guard let id else { throw CameraControlError.photoUnavailable }
            let task = Task<CameraPhotoCommandReceipt, Error> {
                let receipt = try await previews.dispose(id, save: save)
                if save {
                    presentation.present(.savedPreviewID(id))
                    presentation.present(.savedMediaID(receipt.mediaID))
                }
                var issues: [String] = []
                if !receipt.alreadySaved {
                    issues = await PhotoDispositionWorkflow.feedback {
                        try await dispositionFeedback(save: save, invocation: invocation)
                    }
                }
                return .init(
                    previewID: id, mediaID: receipt.mediaID, state: receipt.state,
                    alreadySaved: receipt.alreadySaved, feedbackIssues: issues.isEmpty ? nil : issues)
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

        private func dispositionFeedback(save: Bool, invocation: any FunctionInput) async throws {
            photoFeedbackContext = invocation.context
            defer { photoFeedbackContext = nil }
            guard
                let definition = UIModule.feedbackDefinitions(feedback: self).first(where: {
                    $0.path.function == "playCue"
                })
            else { throw UIActions.FeedbackError.unavailable }
            let child = FunctionInvocation(
                call: FunctionRequest(
                    actionPath: definition.path,
                    parameters: ["cue": save ? "save" : "discard", "volume": "0.85"]),
                context: invocation.context, executionID: UUID().uuidString, results: ActionReportStore())
            let completion = try await FunctionExecutor.perform(child, definition: definition)
            if case .report(let report) = completion, report.hasFailures || report.isCancelled {
                throw PhotoCueFailure(description: report.failureDescription ?? "Photo cue failed")
            }
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

        public func cancelCountdown() async {
            guard state.countdown != nil else { return }
            let pending = photoTask
            pending?.cancel()
            _ = await pending?.result
        }
        public func takePhoto(delaySeconds: Int = 0, invocation: any FunctionInput) async throws -> CameraPhotoReceipt {
            try Task.checkCancellation()
            guard foreground else { throw CameraControlError.notForeground }
            guard photoTask == nil, photoCommand == nil else { throw CameraControlError.busy }
            try ensureCaptureAvailable()
            let expectedRevision = revision
            let task = Task<CameraPhotoReceipt, Error> {
                try await CameraCountdown.wait(seconds: delaySeconds) { presentation.present(.countdown($0)) }
                try Task.checkCancellation()
                guard foreground, revision == expectedRevision else { throw CancellationError() }
                try ensureCaptureAvailable()
                let id = try await previews.reserve()
                defer { previews.cancelReservation(id) }
                try Task.checkCancellation()
                guard foreground, revision == expectedRevision else { throw CancellationError() }
                let rotation = try await presentation.waitForPhotoCaptureRotation()
                try Task.checkCancellation()
                guard foreground, revision == expectedRevision else { throw CancellationError() }
                try ensureCaptureAvailable()
                let data = try await camera.capturePhoto(rotation: CGFloat(rotation))
                try Task.checkCancellation()
                guard foreground, state.isVisible, revision == expectedRevision else { throw CancellationError() }
                guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
                    throw CameraControlError.unavailable
                }
                let width = Int(image.size.width * image.scale)
                let height = Int(image.size.height * image.scale)
                var analysisError: (any Error)?
                do { try await previews.publish(data, id: id, width: width, height: height) } catch {
                    // Preparation failure retains the original. A failed cache publication does not.
                    guard previews.catalog.contains(where: { $0.previewID == id }) else { throw error }
                    analysisError = error
                }
                let receipt = try CameraPhotoReceipt(previewID: id, width: width, height: height)
                try Task.checkCancellation()
                guard foreground, revision == expectedRevision else { throw CancellationError() }
                presentationFinished = nil
                presentation.present(.savedPreviewID(nil))
                presentation.present(.savedMediaID(nil))
                presentation.present(.photoMessage(nil))
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                do {
                    try presentation.presentPhoto(id: id, image: image) { [weak self] success in
                        guard let self, self.state.capturedPhoto?.id == id else { return }
                        self.presentationFinished = (id, success)
                    }
                    while presentationFinished?.id != id {
                        try Task.checkCancellation()
                        guard foreground, revision == expectedRevision else { throw CancellationError() }
                        guard ContinuousClock.now < deadline else { throw CameraPhotoDisplayFailure(previewID: id) }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    guard presentationFinished?.success == true else { throw CameraPhotoDisplayFailure(previewID: id) }
                    presentation.present(.capturedPhoto(nil))
                    if let analysisError {
                        throw CameraPhotoAnalysisFailure(previewID: id, cause: String(describing: analysisError))
                    }
                    return receipt
                } catch {
                    if state.capturedPhoto?.id == id {
                        presentation.present(.capturedPhoto(nil))
                    }
                    throw error
                }
            }
            photoTask = task
            presentation.present(.photoBusy(true))
            defer {
                photoTask = nil
                presentation.present(.countdown(nil))
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
        public let previewID: String
        public var executionFailureCode: ActionExecutionFailureCode { .init(rawValue: "photoPresentationFailed") }
        public var errorDescription: String? {
            "Preview \(previewID) is cached, but its presentation did not complete."
        }
    }

    private struct CameraPhotoAnalysisFailure: Error, LocalizedError {
        let previewID: String
        let cause: String
        var errorDescription: String? { "Preview \(previewID) is cached; image analysis preparation failed: \(cause)" }
    }
#endif
