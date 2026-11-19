import AgentCore
import CoreVideo
import Foundation
import ModelKit
import StorageCore
import Testing

@testable import Agents
@testable import PlatformKit

extension LiveRuntimeTests {
    @Test func nativeBroadcastSeparatesSubscribersAndBoundsSlowConsumers() async throws {
        let source = NativeInputBroadcast<Int>()
        let first = try source.subscribe(.latest)
        let second = try source.subscribe(.latest)
        source.send(1)
        source.send(2)
        var a = first.makeAsyncIterator()
        var b = second.makeAsyncIterator()
        #expect(try await a.next() == 2)
        #expect(try await b.next() == 2)
        #expect(source.replacements == 2)
        source.finish()
        #expect(try await a.next() == nil)
        #expect(try await b.next() == nil)
    }
}

extension LiveRuntimeTests {
    @Test func nativeOrderedOverflowRetainsAcceptedPacketsAndFailsOnlySlowSubscriber() async throws {
        let source = NativeInputBroadcast<Int>()
        let ordered = try source.subscribe(.ordered)
        let latest = try source.subscribe(.latest)
        for value in 0...64 { source.send(value) }
        var packets = ordered.makeAsyncIterator()
        for value in 0..<64 { #expect(try await packets.next() == value) }
        await #expect(throws: NativeSubscriptionError.self) { try await packets.next() }
        var observation = latest.makeAsyncIterator()
        #expect(try await observation.next() == 64)
        source.send(65)
        #expect(try await observation.next() == 65)
        source.finish()
    }
}

@Test func nativeBroadcastRejectsExcessSubscriptionsAndReleasesClosedGeneration() throws {
    let source = NativeInputBroadcast<Int>()
    let streams = try (0..<16).map { _ in try source.subscribe(.latest) }
    #expect(streams.count == 16)
    #expect(throws: NativeSubscriptionError.self) { try source.subscribe(.latest) }
    source.finish()
    _ = try source.subscribe(.latest)
    source.finish()
}

extension LiveRuntimeTests {
    @Test func nativeBroadcastPropagatesProducerFailureToObservers() async throws {
        let broadcast = NativeInputBroadcast<Int>()
        var observer = try broadcast.subscribe(.ordered).makeAsyncIterator()
        broadcast.finish(throwing: NativeSubscriptionError.overflow)
        await #expect(throws: NativeSubscriptionError.self) { _ = try await observer.next() }
    }
}

/// A native-port substitute: no AVFoundation session or system permission request.

@Test func localProcessingContextPreservesCausalityWithoutSignalRouting() throws {
    let context = ProcessingContext(
        requestID: "request", sessionID: "session", generation: "ui-generation",
        source: "user", sequence: 4, rootID: "root", parentID: "parent", hops: 1,
        turn: AgentTurn(id: "turn", ordinal: 2))
    try context.validate()
    let value = context.input(.text("hello"))
    #expect(value.metadata.origin == .local)
    #expect(value.metadata.generation == "ui-generation")
    #expect(value.context.requestID == "request")
    #expect(value.context.rootID == "root")
    #expect(value.context.parentID == "parent")
    #expect(value.turn?.ordinal == 2)
    #expect(throws: CommunicationError.self) { try ProcessingContext(sessionID: "").validate() }
    #expect(throws: CommunicationError.expired) {
        try ProcessingContext(sessionID: "s", deadline: .now.advanced(by: .seconds(-1))).validate()
    }
}

private struct DirectPose: PoseCapability {
    let observed: AsyncStream<InferenceContext>.Continuation
    var availability: CapabilityAvailability { .available }
    func estimatePose(_ request: PoseRequest) -> PoseResult {
        observed.yield(request.context)
        return PoseResult(context: request.context, people: [])
    }
}
private actor DirectCameraFrames: CameraFrameObserving {
    private var frames = AsyncThrowingStream<CameraFrame, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private(set) var subscriptions = 0
    func subscribeFrames() -> AsyncThrowingStream<CameraFrame, any Error> {
        if subscriptions > 0 {
            frames = AsyncThrowingStream<CameraFrame, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        }
        subscriptions += 1
        return frames.stream
    }
    @discardableResult func send(_ frame: CameraFrame) -> Bool {
        if case .terminated = frames.continuation.yield(frame) { return false }
        return true
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, .timeLimit(.minutes(1)))
    func visionSubscribesToNativeCapabilityAndFencesWrongCaptureGeneration()
        async throws
    {
        var pixels: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess)
        let source = DirectCameraFrames()
        let observations = AsyncStream<InferenceContext>.makeStream(bufferingPolicy: .bufferingOldest(4))
        var inferred = observations.stream.makeAsyncIterator()
        let context = try AgentContextRepository(
            agent: .visionPerception, scope: "direct-camera-test", state: VisionPerceptionContextState())
        let role = try VisionPerceptionAgent(
            pose: DirectPose(observed: observations.continuation), sessionID: "generation",
            cameraInput: source, sampling: FrameSamplingConfiguration(initialInterval: 0), context: context)
        #expect(await source.subscriptions == 0)
        try await role.start()
        #expect(await source.subscriptions == 1)
        let frame = CameraFrame(
            width: 16, height: 16, pixels: try #require(pixels), gray64: Data(repeating: 0, count: 4096), sequence: 1,
            timestamp: 1, capturedAt: .now, rotation: 0)
        await #expect(throws: CommunicationError.scopeClosed) { try await role.receive(frame, generation: "previous") }
        let expired = CameraFrame(
            width: 16, height: 16, pixels: try #require(pixels), gray64: Data(repeating: 0, count: 4096),
            sequence: 1, timestamp: 1, capturedAt: .now.advanced(by: .seconds(-1)), rotation: 0)
        await #expect(throws: CommunicationError.expired) {
            try await role.receive(expired, generation: "generation")
        }
        #expect(await role.expiredInputs == 1)
        #expect(await role.status().queuedInputs == 0)
        let fresh = CameraFrame(
            width: 16, height: 16, pixels: try #require(pixels), gray64: Data(repeating: 0, count: 4096), sequence: 1,
            timestamp: 1, capturedAt: .now, rotation: 0)
        await source.send(fresh)
        let request = try #require(await inferred.next())
        #expect(request.scopeID == "generation")
        try await role.pause()
        #expect(await role.status().lifecycle == .paused)
        #expect(await !source.send(fresh))
        try await role.resume()
        #expect(await source.subscriptions == 2)
        let resumed = CameraFrame(
            width: 16, height: 16, pixels: try #require(pixels), gray64: Data(repeating: 1, count: 4096), sequence: 2,
            timestamp: 2, capturedAt: .now, rotation: 0)
        await source.send(resumed)
        #expect(try #require(await inferred.next()).scopeID == "generation")
        await role.stop()
        #expect(await role.status().lifecycle == .stopped)
        await #expect(throws: HarnessError.notRunning) { try await role.receive(frame, generation: "generation") }
    }
}

@Test func nativePCMRetainsFloatSamplesAndUsesTheSameLayoutBounds() throws {
    let values: [Float] = [0.1, 0.2, 0.3, 0.4]
    let audio = try AudioInput(
        samples: values, sampleRate: 48_000, sequence: 7, timestamp: 2,
        layout: .firstOrderAmbisonicsACNSN3D)
    #expect(audio.samples == values)
    #expect(audio.sampleCount == 4 && audio.frameCount == 1)
    #expect(throws: AudioValidationError.self) {
        try AudioInput(samples: [Float.nan], sampleRate: 48_000, sequence: 0, timestamp: 0)
    }
}

@Test func localInputsKeepFieldBoundsAndHaveNoCommunicationSchemas() throws {
    let oversized = String(repeating: "x", count: 129)
    let requests = [
        try ProviderDiscoveryIntent(requestID: oversized).input(sessionID: "session"),
        try ProviderSettingsIntent(operation: .restore, requestID: oversized).input(sessionID: "session"),
        try MemoryHistoryIntent.delete(oversized).input(sessionID: "session"),
        try PhotographerCameraIntent(.savePhoto, previewID: oversized, requestID: "request").input(
            sessionID: "session"),
    ]
    for input in requests {
        guard case .observation(let message) = input.payload else {
            Issue.record("A local typed request must preserve its domain value")
            continue
        }
        #expect(throws: CommunicationError.invalidPayload) { try input.validate(message) }
    }
    #expect(throws: CommunicationError.invalidPayload) {
        try AgentTaskInputIntent(taskID: oversized, interactionID: "interaction", text: "hello")
    }
    let contracts = try AgentContracts.communication
    for name in [
        "user.text", "runtime.event", "media.audio", "media.image", "container.failure", "runtime.failure",
        "provider.discovery", "provider.settings", "history.intent", "photography.camera", "app.environment",
        "app.interaction", "camera.state", "speech.listening", "speech.captureEnded", "agent.userInput",
    ] {
        #expect(contracts[name] == nil)
    }
    #expect(contracts["vision.pose"] != nil && contracts["runtime.action.result"] != nil)
}

extension LiveRuntimeTests {
    @Test func microphoneSourceHasOneConsumerOne64PacketBufferAndPreservesFailure() async throws {
        let source = MicrophoneCapture()
        for sequence in UInt64(0)..<64 {
            try source.send(MicrophoneFrame(samples: [0], sampleRate: 16000, sequence: sequence))
        }
        let capture = try source.subscribe()
        #expect(capture.generation == source.generation)
        #expect(throws: AudioIOError.busy) { try source.subscribe() }
        #expect(throws: AudioIOError.overflow) {
            try source.send(MicrophoneFrame(samples: [0], sampleRate: 16000, sequence: 64))
        }
        source.finish()  // Cleanup must retain the original overflow.
        var packets = capture.frames.makeAsyncIterator()
        for sequence in UInt64(0)..<64 { #expect(try await packets.next()?.sequence == sequence) }
        await #expect(throws: AudioIOError.overflow) { try await packets.next() }
        #expect(!source.isActive)
    }
}

extension LiveRuntimeTests {
    @Test func stoppedMicrophoneCallbacksCannotWriteIntoAReplacementCapture() async throws {
        let old = MicrophoneCapture()
        let first = try old.subscribe()
        try old.send(MicrophoneFrame(samples: [0.1], sampleRate: 16000, sequence: 7))
        old.finish()
        let current = MicrophoneCapture()
        let second = try current.subscribe()
        #expect(first.generation != second.generation)
        #expect(try !old.send(MicrophoneFrame(samples: [0.9], sampleRate: 16000, sequence: 8)))
        old.finish(throwing: AudioIOError.interrupted)
        try current.send(MicrophoneFrame(samples: [0.2], sampleRate: 16000, sequence: 0))
        current.finish(throwing: AudioIOError.interrupted)
        var a = first.frames.makeAsyncIterator()
        var b = second.frames.makeAsyncIterator()
        #expect(try await a.next()?.sequence == 7)
        #expect(try await a.next() == nil)
        #expect(try await b.next()?.samples == [0.2])
        await #expect(throws: AudioIOError.interrupted) { try await b.next() }
    }
}
