import Actions
import AgentCore
import CoreVideo
import Foundation
import Gateway
import UI

@testable import Agents
@testable import PlatformKit

/// Test-only local input. Production UI and native capabilities supply their own typed receipts.
extension AgentManager {
    func receiveLocally(_ input: AgentInput, to target: AgentID) async throws -> DeliveryReport {
        switch input.payload {
        case .actionResult, .toolResult, .roundResult, .activityEvent, .communicationReceipt:
            throw CommunicationError.unauthorized
        default: break
        }
        let receiver = try agent(target)
        do {
            try await receiver.receive(input)
            return DeliveryReport(delivered: [target])
        } catch { return DeliveryReport(rejected: [target: String(describing: error)]) }
    }
    func publishLocally(_ input: AgentInput, to target: AgentID) async throws {
        try await agent(target).receive(input)
    }
}

/// Fixture convenience only: submissions use the real UI request source and role-owned receipts.
@MainActor struct ResourceTestRuntime {
    nonisolated let host: ApplicationControlExecutionSession
    let ui: UIContainer
    let resources: UIModelResourcesContainer
    let settings: UISettingsContainer
    let inventoryProbe: ResourceInventoryProbe
    nonisolated var agent: ApplicationControlAgent { host.agent }
    func prepareForInteraction() async throws { try await host.prepareForInteraction() }
    func shutdown() async {
        await host.shutdown()
        await ui.stop()
    }
    func perform(_ value: ModelResourceIntent) async throws {
        try await prepareForInteraction()
        let input: ResourcesInput
        switch value {
        case .download(let id, let endpoint, let cellular):
            input = .download(id, .init(endpoint: endpoint, allowsCellular: cellular))
        case .cancel(let id): input = .cancel(id)
        case .remove(let id): input = .remove(id)
        case .configureSpeech(let recognition, let synthesis):
            input = .save(.init(useCustomRecognition: recognition, useCustomSynthesis: synthesis))
        default: throw CommunicationError.unsupportedContract
        }
        if case .cancel = input {
            _ = try await resources.requests.submitControl(input)
        } else {
            _ = try await resources.requests.submit(input)
        }
    }
    func discover(_ draft: CloudSettingsDraft) async throws -> [String] {
        try await prepareForInteraction()
        guard case .models(let models) = try await settings.requests.submit(.discover(draft)) else {
            throw CommunicationError.invalidPayload
        }
        return models
    }
    func restoreSettings() async throws -> CloudSettingsDraft {
        try await prepareForInteraction()
        guard case .draft(let value) = try await settings.requests.submit(.restore) else {
            throw CommunicationError.invalidPayload
        }
        return value
    }
    func saveSettings(_ draft: CloudSettingsDraft) async throws {
        try await prepareForInteraction()
        _ = try await settings.requests.submit(.save(draft))
    }
    func controlDevice(_ parameters: [String: String]) async throws {
        try await prepareForInteraction()
        _ = try await ui.devices.requests.submit(DeviceInput(parameters))
    }
    func inventory() async throws -> String { try await refresh(nil) }
    func presentInventory(generation: UInt64) async throws -> String { try await refresh(generation) }
    private func refresh(_ generation: UInt64?) async throws -> String {
        try await prepareForInteraction()
        _ = try await resources.requests.submit(.refresh(generation))
        return try await inventoryProbe.latest().encoded()
    }
    func preferences(_ intent: ModelResourceIntent) async throws -> String {
        try await prepareForInteraction()
        let value: ResourcesInput
        switch intent {
        case .restoreSource: value = .restore
        case .saveSource(let endpoint, let cellular, let recognition, let synthesis):
            value = .save(
                .init(
                    endpoint: endpoint, allowsCellular: cellular,
                    useCustomRecognition: recognition, useCustomSynthesis: synthesis))
        default: throw CommunicationError.unauthorized
        }
        guard case .source(let result) = try await resources.requests.submit(value) else {
            throw CommunicationError.invalidPayload
        }
        return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }
}
actor ResourceInventoryProbe: ModelResourceInventoryCapability {
    let capability: any ModelResourceInventoryCapability
    private var value: ModelResourceInventory?
    init(_ capability: any ModelResourceInventoryCapability) { self.capability = capability }
    func snapshotResources() async throws -> [ModelResourceFact] {
        let items = try await capability.snapshotResources()
        value = ModelResourceInventory(items: items)
        return items
    }
    func latest() throws -> ModelResourceInventory {
        guard let value else { throw CommunicationError.invalidPayload }
        return value
    }
}
actor ResourceTestPreferences: ModelResourcePreferencesCapability {
    private var value = ModelResourcePreferences()
    func restoreSource() -> ModelResourcePreferences { value }
    func saveSource(_ value: ModelResourcePreferences) -> ModelResourcePreferences {
        self.value = value
        return value
    }
}
@MainActor struct HistoryTestRuntime {
    nonisolated let host: MemoryExecutionSession
    let ui: UIContainer
    let history: UIHistoryContainer
    nonisolated var agent: MemoryAgent { host.agent }
    func prepareForInteraction() async throws { try await host.prepareForInteraction() }
    func shutdown() async {
        await host.shutdown()
        await ui.stop()
    }
    func refresh() async throws { _ = try await submit(.refresh) }
    func startNew() async throws { _ = try await submit(.startNew) }
    func summarize(_ id: String) async throws { _ = try await submit(.summarize(id)) }
    func deleteArchived(_ id: String) async throws { _ = try await submit(.delete(id)) }
    func query(_ query: HistoryReadQuery) async throws -> HistoryReply {
        let value: HistoryInput
        switch query {
        case .conversation(let id): value = .conversation(id)
        case .message(let id): value = .message(id)
        case .page(let id, let after, let task): value = .page(id, after, task)
        case .archives(let before): value = .archives(before)
        }
        return try await submit(value)
    }
    private func submit(_ value: HistoryInput) async throws -> HistoryReply {
        try await prepareForInteraction()
        return try await history.requests.submit(value)
    }
}
@MainActor struct CameraTestRuntime {
    nonisolated let host: PhotographerExecutionSession
    let ui: UIContainer
    let camera: UICameraContainer
    nonisolated var agent: PhotographerAgent { host.agent }
    func prepareForInteraction() async throws { try await host.prepareForInteraction() }
    func shutdown() async {
        await host.shutdown()
        await ui.stop()
    }
    func attachTracking(sessionID: String) async throws { try await host.attachTracking(sessionID: sessionID) }
    func detachTracking(sessionID: String) async { await host.detachTracking(sessionID: sessionID) }
    @discardableResult func perform(
        _ operation: PhotographerCameraIntent.Operation,
        facing: PhotographerCameraIntent.Facing? = nil, previewID: String? = nil
    ) async throws -> String? {
        try await prepareForInteraction()
        guard let kind = CameraInput.Operation(rawValue: operation.rawValue) else {
            throw CommunicationError.unauthorized
        }
        return try await camera.requests.submit(
            .init(kind, facing: facing.map { $0 == .front ? .front : .back }, previewID: previewID))
    }
}

@MainActor final class ResourceProviderPersistence: ProviderSettingsPersistence {
    private var value: ProviderSettings?
    func load() async throws -> ProviderSettings? { value }
    func save(_ value: ProviderSettings?) async throws { self.value = value }
    func service() -> ProviderSettingsService {
        ProviderSettingsService(
            store: self,
            runtime: .init(
                initial: .init(enabled: false, url: "https://example.invalid", key: "", model: "fixture"),
                prepare: { _ in {} }, beginChange: {}, endChange: {}))
    }
}

/// Synthetic media fixtures call the role's typed processing method; no routing or buffering.
func processMicrophoneFixture(_ input: AgentInput, using agent: SpeechPerceptionAgent) async throws {
    guard case .audio(let audio) = input.payload else { throw HarnessError.unsupportedInput }
    guard !input.metadata.expired else { throw CommunicationError.expired }
    let samples = audio.samples
    try await agent.processMicrophone(
        MicrophoneFrame(
            samples: samples, sampleRate: audio.sampleRate, sequence: audio.sequence,
            layout: audio.layout == .mono ? .mono : .firstOrderAmbisonicsACNSN3D,
            timestamp: audio.timestamp, capturedAt: audio.capturedAt),
        sessionID: input.sessionID, captureGeneration: input.metadata.generation ?? input.sessionID)
}

func syntheticCameraFrame(
    width: Int, height: Int, value: UInt8 = 0, gray64: Data? = nil,
    sequence: UInt64, timestamp: Double, rotation: Int = 0,
    capturedAt: ContinuousClock.Instant = .now
) throws -> CameraFrame {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        rotation % 2 == 0 ? width : height, rotation % 2 == 0 ? height : width,
        kCVPixelFormatType_32BGRA, nil, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw ImageInputError.invalidFrame }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let bytes = CVPixelBufferGetBaseAddress(buffer) {
        bytes.initializeMemory(
            as: UInt8.self, repeating: value,
            count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return CameraFrame(
        width: width, height: height, pixels: buffer,
        gray64: gray64 ?? Data(repeating: value, count: 4096), sequence: sequence,
        timestamp: timestamp, capturedAt: capturedAt, rotation: rotation)
}

func syntheticCameraImage(
    width: Int, height: Int, value: UInt8 = 0, gray64: Data? = nil,
    sequence: UInt64, timestamp: Double, rotation: Int = 0,
    capturedAt: ContinuousClock.Instant? = nil
) throws -> ImageInput {
    let frame = try syntheticCameraFrame(
        width: width, height: height, value: value, gray64: gray64,
        sequence: sequence, timestamp: timestamp, rotation: rotation, capturedAt: capturedAt ?? .now)
    return try ImageInput(
        width: width, height: height, attachment: frame,
        sequence: sequence, timestamp: timestamp, rotation: rotation, capturedAt: capturedAt)
}

func processCameraFixture(_ input: AgentInput, using agent: VisionPerceptionAgent) async throws {
    guard case .image(let image) = input.payload,
        let native = image.attachment as? CameraFrame
    else { throw ImageInputError.invalidFrame }
    try await agent.handleCamera(native, context: input.context)
}

actor NativeMicrophoneFixture: AudioCaptureObserving {
    nonisolated let capture = MicrophoneCapture()
    func subscribeCapture() throws -> MicrophoneCaptureInput { try capture.subscribe() }
}

func syntheticAudioInput(
    samples: Data, sampleRate: Int, sequence: UInt64, timestamp: Double,
    layout: AudioChannelLayout = .mono, capturedAt: ContinuousClock.Instant = .now
) throws -> AudioInput {
    guard samples.count.isMultiple(of: MemoryLayout<Float>.size) else {
        throw AudioValidationError.invalidRequest("Invalid synthetic PCM bytes")
    }
    let pcm = samples.withUnsafeBytes { bytes in
        stride(from: 0, to: bytes.count, by: MemoryLayout<Float>.size).map {
            bytes.loadUnaligned(fromByteOffset: $0, as: Float.self)
        }
    }
    return try AudioInput(
        samples: pcm, sampleRate: sampleRate, sequence: sequence,
        timestamp: timestamp, layout: layout, capturedAt: capturedAt)
}
