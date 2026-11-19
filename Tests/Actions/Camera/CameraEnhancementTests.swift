import Agents
import ExecutionRuntime
import Foundation
import FunctionContracts
import PlatformKit
import StorageCore
import StorageFiles
import StorageMedia
import StorageSQLite
import Testing
import UI

@testable import Actions

private func captureInput(
    _ function: String = "startRecording", parameters: [String: String] = [:], module: String = "Video"
)
    -> FunctionInvocation
{
    FunctionInvocation(
        call: .init(actionPath: .init(domain: "Camera", module: module, function: function), parameters: parameters),
        context: .init(source: "assistant", sessionID: "recording-session", inputID: "recording-input"),
        executionID: UUID().uuidString, results: ActionReportStore())
}

@Test @MainActor func cameraCountdownUsesMonotonicDeadlinesAndClearsOnCancellation() async throws {
    let now = ContinuousClock.now
    var shown: [Int?] = []
    var deadlines: [ContinuousClock.Instant] = []
    try await CameraCountdown.wait(seconds: 3, now: now, publish: { shown.append($0) }, sleep: { deadlines.append($0) })
    #expect(shown == [3, 2, 1, nil])
    #expect(deadlines == [1, 2, 3].map { now.advanced(by: .seconds($0)) })
    shown = []
    await #expect(throws: CancellationError.self) {
        try await CameraCountdown.wait(
            seconds: 10, publish: { shown.append($0) }, sleep: { _ in throw CancellationError() })
    }
    #expect(shown == [10, nil])
    shown = []
    try await CameraCountdown.wait(
        seconds: 0, publish: { shown.append($0) }, sleep: { _ in Issue.record("Immediate capture must not sleep") })
    #expect(shown == [nil])
}

private actor CameraCommandProbe: CameraControlCapability {
    var settings: [CameraCaptureSettings.Update] = []
    var unloaded: [String] = []
    var selections: [[String]] = []
    func loadPreviewImages(_ ids: [String], invocation: any FunctionInput) -> String {
        selections.append(ids)
        return "selected"
    }
    func saveAllPhotos(invocation: any FunctionInput) -> CameraPhotoBatchReceipt {
        .init(saved: [.init(previewID: "preview_1", mediaID: "media_1", state: .saved)])
    }
    func configureCapture(_ settings: CameraCaptureSettings.Update, invocation: any FunctionInput) {
        self.settings.append(settings)
    }
    func unloadPreviewImage(_ id: String, invocation: any FunctionInput) throws {
        guard id == "preview_1" else { throw CameraControlError.photoUnavailable }
        unloaded.append(id)
    }
    func setEnabled(_ enabled: Bool, invocation: any FunctionInput) {}
    func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) {}
}
@Test func cameraPhotoBatchActionsValidateParametersAndReturnResults() async throws {
    let probe = CameraCommandProbe()
    let definitions = CameraModule(camera: probe).definitions
    let load = try #require(definitions.first { $0.path.function == "loadPreviewImage" })
    let save = try #require(definitions.first { $0.path.function == "saveAllPhotos" })
    let ids = (1...5).map { "preview_\($0)" }
    let array = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
    let loaded = try await FunctionExecutor.perform(
        captureInput("loadPreviewImage", parameters: ["previewIDs": array], module: "Capture"), definition: load)
    #expect(loaded == .value("selected"))
    for parameters in [
        ["previewIDs": array, "previewID": "preview_1"],
        ["previewIDs": #"["preview_1","preview_1"]"#],
        ["previewIDs": #"["media_1"]"#],
    ] {
        await #expect(throws: ActionArguments.ValidationError.self) {
            _ = try await FunctionExecutor.perform(
                captureInput("loadPreviewImage", parameters: parameters, module: "Capture"), definition: load)
        }
    }
    #expect(await probe.selections == [ids])
    let completion = try await FunctionExecutor.perform(
        captureInput("saveAllPhotos", module: "Capture"), definition: save)
    guard case .value(let json) = completion else {
        Issue.record("Missing batch receipt")
        return
    }
    let receipt = try JSONDecoder().decode(CameraPhotoBatchReceipt.self, from: Data(json.utf8))
    #expect(receipt.saved.first?.mediaID == "media_1")
}

@Test func cameraSettingsValidateBeforeCallingHardware() async throws {
    let probe = CameraCommandProbe()
    let configure = try #require(CameraModule(camera: probe).definitions.first { $0.path.function == "configure" })
    for parameters in [
        ["delaySeconds": "31"], ["zoom": "nan"], ["zoom": "0"], ["flash": "torch"], ["mode": "portrait"],
        ["durationSeconds": "0"], ["extra": "true"],
    ] {
        await #expect(throws: (any Error).self) {
            _ = try await FunctionExecutor.perform(
                captureInput("configure", parameters: parameters, module: "Capture"), definition: configure)
        }
    }
    #expect(await probe.settings.isEmpty)
    let completion = try await FunctionExecutor.perform(
        captureInput(
            "configure", parameters: ["mode": "video", "durationSeconds": "10", "zoom": "2"], module: "Capture"),
        definition: configure)
    #expect(completion == .completed)
    #expect(await probe.settings == [.init(mode: "video", zoom: 2, durationSeconds: 10)])
    let settings = CameraCaptureSettings(mode: "video", zoom: 2, durationSeconds: 10)
    let message = PhotographerCameraIntent(.configure, settings: settings, requestID: UUID().uuidString).message
    #expect(message.photographerCamera?.settings == settings)
}

@Test func unloadingCameraPreviewReturnsOnlyCompletionAndPreservesErrors() async throws {
    let probe = CameraCommandProbe()
    let unload = try #require(
        CameraModule(camera: probe).definitions.first { $0.path.function == "unloadPreviewImage" })
    let completion = try await FunctionExecutor.perform(
        captureInput("unloadPreviewImage", parameters: ["previewID": "preview_1"], module: "Capture"),
        definition: unload)
    #expect(completion == .completed)
    await #expect(throws: CameraControlError.self) {
        _ = try await FunctionExecutor.perform(
            captureInput("unloadPreviewImage", parameters: ["previewID": "preview_2"], module: "Capture"),
            definition: unload)
    }
    #expect(await probe.unloaded == ["preview_1"])
}

/// Synthetic native callbacks exercise domain ownership, not AVFoundation encoding or microphone acceptance.
private actor RecordingCameraFixture: CameraCapturing {
    nonisolated let events = AsyncStream<CameraEvent> { $0.finish() }
    let captureRotation: CGFloat = 0
    let file: URL
    let id = UUID().uuidString
    var started = false
    var trace: [String] = []
    var duration: Int?
    var failConfiguration = false
    var holdConfiguration = false
    let configurationEntered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var configurationWaiter: CheckedContinuation<Void, Never>?
    func configureFailure(held: Bool) {
        failConfiguration = !held
        holdConfiguration = held
    }
    func releaseConfiguration() {
        configurationWaiter?.resume()
        configurationWaiter = nil
    }
    func setVideoMode(_ enabled: Bool) { trace.append("video:\(enabled)") }
    func configurePhoto(flash: CameraFlash, zoom: Double) async throws -> CameraPhotoConfiguration {
        trace.append("settings:\(flash.rawValue):\(zoom)")
        if failConfiguration {
            failConfiguration = false
            throw CameraError.configurationFailed
        }
        if holdConfiguration {
            holdConfiguration = false
            await withCheckedContinuation {
                configurationWaiter = $0
                configurationEntered.continuation.yield(())
            }
            try Task.checkCancellation()
        }
        return .init(flash: flash, zoom: zoom, maximumZoom: 6, supportedFlash: [.off, .on, .auto])
    }
    var recordedRotation: CGFloat?
    var terminal: CameraMovie?
    var waiter: CheckedContinuation<CameraMovie, any Error>?
    init(file: URL) { self.file = file }
    func requestPermission() -> Bool { true }
    func subscribeFrames() -> AsyncThrowingStream<CameraFrame, Error> { .init { $0.finish() } }
    func start(facing: CameraFacing) -> AsyncThrowingStream<CameraFrame, Error> { subscribeFrames() }
    func switchCamera(facing: CameraFacing) -> AsyncThrowingStream<CameraFrame, Error> { subscribeFrames() }
    func capturePhoto(rotation: CGFloat) throws -> Data { throw CameraError.unavailable }
    func isRunning() -> Bool { true }
    func stop() { complete("interrupted") }
    func stopAndWait() { stop() }
    func beginRecording(durationSeconds: Int, rotation: CGFloat) -> String {
        trace.append("start")
        duration = durationSeconds
        started = true
        recordedRotation = rotation
        return id
    }
    func waitForRecording(_ id: String) async throws -> CameraMovie {
        if let terminal { return terminal }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func stopRecording(_ id: String) -> CameraMovie {
        complete("stopped")
        return terminal!
    }
    func complete(_ reason: String) {
        guard terminal == nil else { return }
        let result = CameraMovie(file: file, stopReason: reason)
        terminal = result
        waiter?.resume(returning: result)
        waiter = nil
    }
}

@Test @MainActor func recordingStopsJoinsRestoresAudioAndSavesExactlyOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.mov")
    try Data(repeating: 7, count: 32).write(to: source)
    let records = try SQLiteRepositories(url: root.appendingPathComponent("store.sqlite"))
    let store = MediaStore(
        repository: records.media, files: try DiskFileStore(root: root.appendingPathComponent("media")))
    let ui = UIContainer()
    try ui.start()
    let frame = try syntheticCameraFrame(width: 8, height: 8, sequence: 1, timestamp: 0)
    let native = RecordingCameraFixture(file: source)
    var audio: [String] = []
    var activities: [String?] = []
    let session = CameraRecordingSession(
        camera: native, photos: store, presentation: ui.camera,
        foreground: { true },
        acquireAudio: {
            audio.append("pause")
            try ui.camera.presentVideo(
                frame.withPixelBuffer {
                    CameraVideoFrame(
                        pixels: $0, width: 8, height: 8, rotation: 0, sequence: 1, capturedAt: .now, portraitRotation: 1
                    )
                })
        },
        releaseAudio: { audio.append($0 ? "resume" : "release") },
        activity: { activities.append($0) }, inspect: { _ in .init(width: 1920, height: 1080, duration: 2) })
    var settings = CameraSettings()
    settings.flash = "auto"
    settings.zoom = 2
    settings.delaySeconds = 3
    ui.camera.present(.settings(settings))
    let start = try await session.start(duration: 10, invocation: captureInput())
    #expect(await native.trace == ["video:true", "settings:off:2.0", "start"])
    #expect(await native.duration == 10)
    #expect(ui.camera.snapshot.settings.mode == "video" && ui.camera.snapshot.settings.flash == "off")
    #expect(ui.camera.snapshot.settings.zoom == 2 && ui.camera.snapshot.settings.delaySeconds == 3)
    #expect(ui.camera.snapshot.settings.durationSeconds == 10)
    #expect(start.state == "recording" && ui.camera.snapshot.recording.active)
    #expect(await native.recordedRotation == 90)
    await #expect(throws: CameraControlError.busy) {
        _ = try await session.start(duration: 10, invocation: captureInput())
    }
    let ready = try await session.stop(start.recordingID)
    #expect(ready.state == "ready" && ready.mediaID != nil)
    #expect(audio == ["pause", "resume"])
    #expect(activities.contains("Recording") && activities.contains("Finalizing"))
    #expect(try await store.albumPage().items.isEmpty)
    #expect(ui.camera.snapshot.recordedVideo != nil)
    let saved = try await session.save(start.recordingID)
    #expect(saved.state == "saved")
    #expect(try await session.save(start.recordingID) == saved)
    #expect(try await store.albumPage().items.map(\.id) == [saved.mediaID!])
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(ui.camera.snapshot.recordedVideo == nil && !session.hasClip)
    await #expect(throws: CameraControlError.busy) { _ = try await session.ignore(start.recordingID) }
    try await records.shutdown()
}

@Test @MainActor func timedRecordingAndBackgroundRetainClipWithoutResumingListening() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.mov")
    try Data([1, 2, 3]).write(to: source)
    let records = try SQLiteRepositories(url: root.appendingPathComponent("store.sqlite"))
    let store = MediaStore(
        repository: records.media, files: try DiskFileStore(root: root.appendingPathComponent("media")))
    let ui = UIContainer()
    try ui.start()
    let frame = try syntheticCameraFrame(width: 8, height: 8, sequence: 1, timestamp: 0)
    let native = RecordingCameraFixture(file: source)
    var foreground = true
    var resumed: [Bool] = []
    let session = CameraRecordingSession(
        camera: native, photos: store, presentation: ui.camera,
        foreground: { foreground },
        acquireAudio: {
            try ui.camera.presentVideo(
                frame.withPixelBuffer {
                    CameraVideoFrame(
                        pixels: $0, width: 8, height: 8, rotation: 0, sequence: 1, capturedAt: .now, portraitRotation: 1
                    )
                })
        }, releaseAudio: { resumed.append($0) }, activity: { _ in },
        inspect: { _ in .init(width: 1920, height: 1080, duration: 1) })
    var configured = CameraSettings()
    configured.mode = "video"
    configured.durationSeconds = 1
    ui.camera.present(.settings(configured))
    let start = try await session.start(duration: 1, invocation: captureInput())
    #expect(await native.trace == ["start"])
    foreground = false
    session.invalidateForeground()
    // Even a quick foreground return cannot revive the old recording's listening permit.
    foreground = true
    await native.complete("durationLimit")
    await session.background()
    #expect(resumed == [false])
    #expect(ui.camera.snapshot.recording.phase == .ready && session.hasClip)
    let receipt = try await session.stop(start.recordingID)
    #expect(receipt.stopReason == "durationLimit")
    _ = try await session.ignore(start.recordingID)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try await store.albumPage().items.isEmpty)
    #expect(try records.media.retainedMedia().isEmpty)
    try await records.shutdown()
}

@Test func videoFilesPreserveOwnershipAndNeverEnterImageReads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.mov")
    try Data([1, 2, 3]).write(to: source)
    let records = try SQLiteRepositories(url: root.appendingPathComponent("store.sqlite"))
    let store = MediaStore(
        repository: records.media, files: try DiskFileStore(root: root.appendingPathComponent("media")),
        limits: .init(maximumPhotos: 1, maximumBytes: 8, overflowPolicy: .evictOldest))
    let owner = StorageOwner(namespace: "photos", source: "assistant", session: "s", input: "i")
    let metadata = MediaMetadata(mime: "video/quicktime", width: 1920, height: 1080, capturedAt: nil, origin: "camera")
    let id = try await store.saveVideo(source, owner: owner, metadata: metadata)
    #expect(try Data(contentsOf: await store.videoURL(id, owner: owner)) == Data([1, 2, 3]))
    await #expect(throws: FileStorageError.invalidFile) { _ = try await store.videoURL(id) }
    await #expect(throws: FileStorageError.invalidFile) { _ = try await store.read(id, owner: owner) }
    await #expect(throws: FileStorageError.invalidFile) {
        _ = try await store.videoURL(id, owner: .init(namespace: "photos", source: "other", session: "s", input: "i"))
    }
    try await store.collectVideo(id, owner: owner)
    #expect(try await store.isAlbumVideo(id))
    await #expect(throws: FileStorageError.invalidFile) { try await store.discardVideo(id, owner: owner) }
    await #expect(throws: FileStorageError.capacityExceeded) {
        _ = try await store.saveVideo(source, owner: owner, metadata: metadata)
    }
    try await store.deleteAlbum(id)
    #expect(try await store.albumPage().items.isEmpty)
    try await records.shutdown()
}

@Test @MainActor func cancelledRecordingPreparationJoinsAndReleasesListeningWithoutStartingCamera() async throws {
    let database = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    let records = try SQLiteRepositories(url: database, removeOnClose: true)
    let ui = UIContainer()
    try ui.start()
    let native = RecordingCameraFixture(
        file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov"))
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var releaseCount = 0
    let session = CameraRecordingSession(
        camera: native,
        photos: MediaStore(repository: records.media, files: try MemoryFileStore()), presentation: ui.camera,
        foreground: { true },
        acquireAudio: {
            entered.continuation.yield(())
            try await Task.sleep(for: .seconds(60))
        }, releaseAudio: { _ in releaseCount += 1 }, activity: { _ in })
    var starts = entered.stream.makeAsyncIterator()
    let starting = Task { try await session.start(duration: 10, invocation: captureInput()) }
    await starts.next()
    starting.cancel()
    await #expect(throws: CancellationError.self) { _ = try await starting.value }
    #expect(await native.started == false)
    #expect(releaseCount == 1 && !session.busy && !session.hasClip)
    #expect(ui.camera.snapshot.recording.phase == .failed)
    try await records.shutdown()
}

@MainActor private final class RecordingAudioOwnerFixture: AudioCaptureControlling {
    let captureContext = AudioCaptureContext()
    var cleanupFailure: (any Error)?
    var owned = true
    var trace: [String] = []
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var stopWaiter: CheckedContinuation<Void, Never>?
    func requestPermissions() async throws {}
    func subscribeEvents() throws -> AsyncThrowingStream<NativeAudioEvent, any Error> { .init { $0.finish() } }
    func subscribeCapture() async throws -> MicrophoneCaptureInput { throw AudioIOError.busy }
    func startCapture(preferSpatial: Bool) async throws { owned = true }
    func stopCapture() async { trace.append("samplesStopped") }
    func stop() async {
        trace.append("joiningSession")
        await withCheckedContinuation {
            stopWaiter = $0
            entered.continuation.yield(())
        }
        owned = false
        trace.append("sessionReleased")
    }
    func release() {
        stopWaiter?.resume()
        stopWaiter = nil
    }
}

@Test(arguments: ["success", "cancelled", "cleanupFailure"]) @MainActor
func recordingAudioHandoffWaitsForSessionOwnerRelease(_ outcome: String) async throws {
    let audio = RecordingAudioOwnerFixture()
    if outcome == "cleanupFailure" { audio.cleanupFailure = AudioIOError.interrupted }
    var entered = audio.entered.stream.makeAsyncIterator()
    let operation = Task {
        try await VoiceRecordingAudioHandoff.run(audio: audio) {
            await audio.stopCapture()
            if outcome == "cancelled" { throw CancellationError() }
        }
        audio.trace.append("cameraMayAcquire")
    }
    await entered.next()
    #expect(audio.owned && audio.trace == ["samplesStopped", "joiningSession"])
    audio.release()
    if outcome == "success" {
        try await operation.value
        #expect(audio.trace.last == "cameraMayAcquire")
    } else if outcome == "cancelled" {
        await #expect(throws: CancellationError.self) { try await operation.value }
    } else {
        await #expect(throws: PlatformFailure.self) { try await operation.value }
    }
    #expect(!audio.owned && audio.trace.contains("sessionReleased"))
    if outcome != "success" { #expect(!audio.trace.contains("cameraMayAcquire")) }
}

@Test(.timeLimit(.minutes(1)), arguments: ["stopped", "durationLimit", "cancelled", "invalidFile"]) @MainActor
func recordingTerminalWaitJoinsSingleFileAndPublishesBeforeAudioResume(_ ending: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("recording.mov")
    try Data([1, 2, 3]).write(to: file)
    let records = try SQLiteRepositories(url: root.appendingPathComponent("store.sqlite"))
    let store = MediaStore(
        repository: records.media, files: try DiskFileStore(root: root.appendingPathComponent("media")))
    let ui = UIContainer()
    try ui.start()
    let frame = try syntheticCameraFrame(width: 8, height: 8, sequence: 1, timestamp: 0)
    let native = RecordingCameraFixture(file: file)
    var releases: [CameraRecordingPresentation.Phase] = []
    let session = CameraRecordingSession(
        camera: native, photos: store, presentation: ui.camera, foreground: { true },
        acquireAudio: {
            try ui.camera.presentVideo(
                frame.withPixelBuffer {
                    CameraVideoFrame(
                        pixels: $0, width: 8, height: 8, rotation: 0, sequence: 1, capturedAt: .now, portraitRotation: 1
                    )
                })
        },
        releaseAudio: { _ in releases.append(ui.camera.snapshot.recording.phase) }, activity: { _ in },
        inspect: { _ in
            if ending == "invalidFile" { throw CameraControlError.unavailable }
            return .init(width: 1920, height: 1080, duration: 4.8)
        })
    let started = try await session.start(duration: 10, invocation: captureInput())
    let waiting = Task { try await session.wait(started.recordingID) }
    if ending == "cancelled" {
        waiting.cancel()
    } else {
        await native.complete(ending == "invalidFile" ? "stopped" : ending)
    }
    if ending == "cancelled" {
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        #expect(releases == [.ready])
    } else if ending == "invalidFile" {
        await #expect(throws: CameraControlError.unavailable) { _ = try await waiting.value }
        #expect(releases == [.failed])
    } else {
        let ready = try await waiting.value
        #expect(ready.state == "ready" && ready.durationSeconds == 4.8 && ready.stopReason == ending)
        #expect(ready.mediaID != nil && ready.fileName?.hasSuffix(".mov") == true)
        #expect(ready.fileName?.contains("/") == false)
        #expect(releases == [.ready])
        // Repeated completion reads join the same result and do not prepare another file.
        #expect(try await session.wait(started.recordingID) == ready)
        #expect(try await session.stop(started.recordingID) == ready)
    }
    #expect(!ui.camera.snapshot.recording.active && session.hasClip)
    #expect(releases.count == 1)
    _ = try await session.ignore(started.recordingID)
    #expect(try records.media.retainedMedia().isEmpty)
    await ui.stop()
    try await records.shutdown()
}

@Test func recordingCompletionModeValidatesBeforeEffectsAndHasBoundedBudgets() async throws {
    let camera = CameraCommandProbe()
    for parameters in [
        ["waitForCompletion": "yes"], ["unexpected": "true"], ["durationSeconds": "0"],
        ["durationSeconds": "601"], ["durationSeconds": "nan"], ["durationSeconds": "1.5"],
    ] {
        await #expect(throws: ActionArguments.ValidationError.self) {
            _ = try await CameraActions.startRecording(invocation: captureInput(parameters: parameters), using: camera)
        }
    }
    let definition = try #require(
        CameraModule(camera: camera).definitions.first { $0.path.function == "startRecording" })
    #expect(try definition.executionBudget(for: captureInput().call).timeout == .seconds(780))
    #expect(
        try definition.executionBudget(for: captureInput(parameters: ["waitForCompletion": "false"]).call).timeout
            == .seconds(120))
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func recordingConfigurationFailureOrCancellationRollsBackWithoutAudioOrCapture(_ cancel: Bool) async throws {
    let database = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    let records = try SQLiteRepositories(url: database, removeOnClose: true)
    let ui = UIContainer()
    try ui.start()
    var settings = CameraSettings()
    settings.flash = "auto"
    settings.zoom = 2
    ui.camera.present(.settings(settings))
    let camera = RecordingCameraFixture(
        file: FileManager.default.temporaryDirectory.appendingPathComponent("unused.mov"))
    await camera.configureFailure(held: cancel)
    var audioAcquired = 0
    let session = CameraRecordingSession(
        camera: camera, photos: MediaStore(repository: records.media, files: try MemoryFileStore()),
        presentation: ui.camera, foreground: { true }, acquireAudio: { audioAcquired += 1 },
        releaseAudio: { _ in Issue.record("No audio was acquired") }, activity: { _ in })
    let starting = Task { try await session.start(duration: 10, invocation: captureInput()) }
    if cancel {
        var entered = camera.configurationEntered.stream.makeAsyncIterator()
        await entered.next()
        starting.cancel()
        await camera.releaseConfiguration()
        await #expect(throws: CancellationError.self) { _ = try await starting.value }
    } else {
        await #expect(throws: CameraError.configurationFailed) { _ = try await starting.value }
    }
    #expect(await camera.trace == ["video:true", "settings:off:2.0", "video:false", "settings:auto:2.0"])
    #expect(await camera.started == false)
    #expect(audioAcquired == 0 && !session.busy && !session.hasClip)
    #expect(ui.camera.snapshot.settings.mode == "photo" && ui.camera.snapshot.settings.flash == "auto")
    #expect(ui.camera.snapshot.settings.zoom == 2 && ui.camera.snapshot.recording.phase == .failed)
    await ui.stop()
    try await records.shutdown()
}

/// Deterministic device/window boundary; exercises real CameraModule dispatch, not AVFoundation.
private actor AutomaticCaptureProbe: CameraControlCapability {
    var trace: [String] = []
    var photoDelays: [Int?] = []
    let denyOpen: Bool
    let failCapture: Bool
    init(denyOpen: Bool = false, failCapture: Bool = false) {
        self.denyOpen = denyOpen
        self.failCapture = failCapture
    }
    func setEnabled(_ enabled: Bool, invocation: any FunctionInput) throws {
        trace.append("open")
        #expect(invocation.call.actionPath.description == "Camera.Capture.open")
        #expect(invocation.call.parameters.isEmpty)
        #expect(invocation.context.inputID == "recording-input")
        if denyOpen { throw CameraControlError.permissionDenied }
    }
    func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) {}
    func takePhoto(delaySeconds: Int?, invocation: any FunctionInput) throws -> CameraPhotoReceipt {
        trace.append("photo")
        photoDelays.append(delaySeconds)
        if failCapture { throw CameraControlError.busy }
        return try .init(previewID: "media_151", width: 640, height: 480)
    }
    func startRecording(durationSeconds: Int?, invocation: any FunctionInput) throws -> CameraVideoReceipt {
        trace.append("video:\(durationSeconds ?? 600)")
        if failCapture { throw CameraControlError.busy }
        return .init(recordingID: "11111111-2222-4333-8444-555555555555", state: "recording")
    }
    func waitForRecording(_ id: String, invocation: any FunctionInput) -> CameraVideoReceipt {
        trace.append("ready")
        return .init(
            recordingID: id, state: "ready", mediaID: "media_152", durationSeconds: 10,
            stopReason: "durationLimit", fileName: "video.mov")
    }
}

@Test(.actionCatalog, arguments: [false, true])
func openingCameraReturnsOnlyCompletionAndPreservesPermissionFailure(_ deny: Bool) async throws {
    let camera = AutomaticCaptureProbe(denyOpen: deny)
    let definition = try #require(CameraModule(camera: camera).definitions.first { $0.path.function == "open" })
    let input = captureInput("open", module: "Capture")
    if deny {
        await #expect(throws: CameraControlError.permissionDenied) {
            _ = try await FunctionExecutor.perform(input, definition: definition)
        }
    } else {
        #expect(try await FunctionExecutor.perform(input, definition: definition) == .completed)
    }
    #expect(await camera.trace == ["open"])
}

@Test(.actionCatalog) @MainActor func cameraSettingUpdatesPreserveLatestOmittedFields() async throws {
    let ui = UIContainer()
    try ui.start()
    var settings = CameraSettings()
    settings.mode = "video"
    settings.delaySeconds = 5
    settings.zoom = 2
    settings.durationSeconds = 30
    ui.camera.present(.settings(settings))
    let camera = RecordingCameraFixture(file: URL.temporaryDirectory.appendingPathComponent("unused.mov"))
    try await CameraCaptureConfiguration.applyUpdate(.init(delaySeconds: 0), camera: camera, presentation: ui.camera)
    try await CameraCaptureConfiguration.applyUpdate(.init(zoom: 3), camera: camera, presentation: ui.camera)
    let after = ui.camera.snapshot.settings
    #expect(after.mode == "video" && after.flash == "off")
    #expect(after.delaySeconds == 0 && after.zoom == 3 && after.durationSeconds == 30)
    #expect(await camera.trace == ["video:true", "settings:off:2.0", "video:true", "settings:off:3.0"])
    await ui.stop()
}

@Test(.actionCatalog, arguments: ["video", "interactiveVideo"], ["success", "openFailure", "captureFailure"])
func recordingCompositeReturnsOnlyCaptureResultAndStopsOnPreparationFailure(_ kind: String, _ outcome: String)
    async throws
{
    let camera = AutomaticCaptureProbe(denyOpen: outcome == "openFailure", failCapture: outcome == "captureFailure")
    let parameters = ["durationSeconds": "10", "waitForCompletion": kind == "video" ? "true" : "false"]
    let input = FunctionInvocation(
        call: .init(
            actionPath: .init(domain: "Camera", module: "Video", function: "startRecording"),
            parameters: parameters),
        context: captureInput().context, executionID: UUID().uuidString, results: ActionReportStore())
    let definition = try #require(CameraModule(camera: camera).definitions.first { $0.path == input.call.actionPath })
    let completion = try await FunctionExecutor.perform(input, definition: definition)
    let trace = await camera.trace
    #expect(trace.first == "open")
    if outcome == "success" {
        guard case .value(let value) = completion else {
            Issue.record("Receipt was replaced by child report")
            return
        }
        let receipt = try JSONDecoder().decode(CameraVideoReceipt.self, from: Data(value.utf8))
        #expect(receipt.state == (kind == "video" ? "ready" : "recording"))
        #expect(trace == (kind == "video" ? ["open", "video:10", "ready"] : ["open", "video:10"]))
    } else {
        guard case .report(let report) = completion else {
            Issue.record("Expected step failure report")
            return
        }
        #expect(report.hasFailures)
        #expect(trace.count == (outcome == "openFailure" ? 1 : 2))
        #expect(report.entries.last?.status == (outcome == "openFailure" ? .notStarted : .failed))
        #expect(
            report.entries.contains { $0.code?.rawValue == (outcome == "openFailure" ? "permissionDenied" : "busy") })
    }
}

@Test(.actionCatalog, arguments: ["photo", "video"]) @MainActor
func automaticPhotoModePreservesSettingsAndAvoidsRedundantConfiguration(_ mode: String) async throws {
    let ui = UIContainer()
    try ui.start()
    var settings = CameraSettings()
    settings.mode = mode
    settings.flash = "off"
    settings.zoom = 2
    settings.delaySeconds = 3
    settings.durationSeconds = 10
    ui.camera.present(.settings(settings))
    let camera = RecordingCameraFixture(
        file: FileManager.default.temporaryDirectory.appendingPathComponent("unused.mov"))
    try await CameraCaptureConfiguration.preparePhoto(camera: camera, presentation: ui.camera)
    let after = ui.camera.snapshot.settings
    #expect(after.mode == "photo" && after.zoom == 2 && after.flash == "off")
    #expect(after.delaySeconds == 3 && after.durationSeconds == 10)
    #expect(await camera.trace == (mode == "video" ? ["video:false", "settings:off:2.0"] : []))
    await ui.stop()
}

@Test(.actionCatalog, arguments: [nil, 0, 3, 30] as [Int?])
func photoCountdownForwardsSingleShotOverrideWithoutOpeningOrConfiguring(_ delay: Int?) async throws {
    let camera = AutomaticCaptureProbe(denyOpen: true)
    let endpoint = await CameraExecutionEndpoint(
        camera: camera, rootSessionID: "recording-session", validateSession: { _ in })
    let definition = try #require(CameraModule(camera: endpoint).definitions.first { $0.path.function == "takePhoto" })
    let input = captureInput(
        "takePhoto", parameters: delay.map { ["delaySeconds": String($0)] } ?? [:], module: "Capture")
    let completion = try await FunctionExecutor.perform(input, definition: definition)
    guard case .value(let value) = completion else {
        Issue.record("Missing photo receipt")
        return
    }
    #expect(try JSONDecoder().decode(CameraPhotoReceipt.self, from: Data(value.utf8)).previewID == "media_151")
    #expect(await camera.trace == ["photo"])
    #expect(await camera.photoDelays == [delay])
    #expect(try definition.executionBudget(for: input.call).timeout == .seconds(50))
}

@Test(.actionCatalog, arguments: ["-1", "31", "1.5", "abc", "", "999999999999999999999999"])
func photoCountdownRejectsInvalidValuesBeforeAnyEffect(_ delay: String) async throws {
    let camera = AutomaticCaptureProbe()
    let definition = try #require(CameraModule(camera: camera).definitions.first { $0.path.function == "takePhoto" })
    let input = captureInput("takePhoto", parameters: ["delaySeconds": delay], module: "Capture")
    #expect(throws: (any Error).self) { try definition.validateInput(input) }
    await #expect(throws: (any Error).self) { _ = try await FunctionExecutor.perform(input, definition: definition) }
    #expect(await camera.trace.isEmpty)
}

@Test(.actionCatalog) func photoFailureDoesNotRetryOrImplicitlyOpen() async throws {
    let camera = AutomaticCaptureProbe(failCapture: true)
    let definition = try #require(CameraModule(camera: camera).definitions.first { $0.path.function == "takePhoto" })
    await #expect(throws: CameraControlError.busy) {
        _ = try await FunctionExecutor.perform(captureInput("takePhoto", module: "Capture"), definition: definition)
    }
    #expect(await camera.trace == ["photo"])
}
