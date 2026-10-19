import AgentCore
import Foundation
import PlatformKit

/// One external envelope encoder for domain intents, host facts and registered sensor content.
public enum ExternalInputAdapter {
    static func validSource(_ source: String) -> Bool {
        func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 }
        guard let first = source.utf8.first, source.utf8.count <= 64, letter(first) else { return false }
        return source.utf8.dropFirst().allSatisfy { letter($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }
    }
    public static func signal(_ draft: ExternalInputDraft) throws -> AgentInput {
        let id = draft.id ?? UUID().uuidString
        let rootID = draft.rootID ?? id
        let identities = [id, draft.sessionID, rootID] + [draft.parentID].compactMap { $0 }
        guard identities.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
            validSource(draft.source), (0...8).contains(draft.hops)
        else { throw CommunicationError.invalidPayload }
        if let turn = draft.turn {
            guard !turn.id.isEmpty, turn.id.utf8.count <= 128, turn.ordinal > 0 else {
                throw CommunicationError.invalidPayload
            }
        }
        switch draft.payload {
        case .observation(let message):
            guard message.content(as: AgentTaskSignal.self) == nil else { throw CommunicationError.unauthorized }
            _ = try message.validatedSize()
        case .text(let text):
            guard text.utf8.count <= 4096 else { throw CommunicationError.invalidPayload }
        case .event(let event):
            guard event.utf8.count <= 16384 else { throw CommunicationError.invalidPayload }
        case .audio, .image: break
        case .communicationReceipt, .toolResult, .actionResult, .roundResult, .activityEvent:
            throw CommunicationError.unauthorized
        }
        return AgentInput(
            id: id, sessionID: draft.sessionID, payload: draft.payload,
            metadata: InputMetadata(
                payload: draft.payload, source: draft.source, origin: .external, sequence: draft.sequence,
                rootID: rootID, parentID: draft.parentID, hops: draft.hops, deadline: draft.deadline),
            turn: draft.turn)
    }

    /// Adds host-owned interaction identity without letting a caller change provenance.
    public static func assigningTurn(_ turn: AgentTurn, to input: AgentInput) throws -> AgentInput {
        guard input.metadata.origin == .external, input.metadata.incarnation == nil, input.taskScope == nil else {
            throw CommunicationError.unauthorized
        }
        guard !turn.id.isEmpty, turn.id.utf8.count <= 128, turn.ordinal > 0 else {
            throw CommunicationError.invalidPayload
        }
        return AgentInput(
            id: input.id, sessionID: input.sessionID, payload: input.payload, metadata: input.metadata, turn: turn)
    }
}

extension ExternalInputProviding {
    public func input(sessionID: String, sequence: UInt64 = 0) throws -> AgentInput {
        try ExternalInputAdapter.signal(externalInput(sessionID: sessionID, sequence: sequence))
    }
}

/// Native ingress codecs. The foundation SDK never constructs transport identities.
public enum DeviceInputAdapter {
    static func isLifecycleControl(module: String, error: any Error) -> Bool {
        guard module == "platform" else { return false }
        if let failure = error as? PlatformFailure, failure.code == .cleanupFailed || !failure.cleanupErrors.isEmpty {
            return false
        }
        guard let error = ((error as? PlatformFailure)?.underlying ?? error) as? PlatformError else { return false }
        return error == .unavailable || error == .stopped
    }

    static func bluetoothFailureCode(module: String, component: String, operation: String, error: any Error) -> String?
    {
        guard module == "platform", component == "connectivity.bluetooth" else { return nil }
        if let failure = error as? PlatformFailure, failure.code == .cleanupFailed || !failure.cleanupErrors.isEmpty {
            return nil
        }
        let error = (error as? PlatformFailure)?.underlying ?? error
        if operation == "connect", error as? NexArmError == .timeout {
            return "bluetooth.connectionUnavailable"
        }
        if let error = error as? NexArmBluetoothError {
            switch error {
            case .unavailable: return "bluetooth.unavailable"
            case .unknownDevice: return "bluetooth.deviceUnavailable"
            case .incompatibleService: return "bluetooth.connectionUnavailable"
            case .packetTooLarge: return nil
            }
        }
        let step: NexArmBluetoothStep
        switch error as? NexArmBluetoothFailure {
        case .timeout(let value), .incompatibleService(let value): step = value
        case .native(let value, _, _): step = value
        default: return nil
        }
        switch step {
        case .connecting, .services, .characteristics, .notifications: return "bluetooth.connectionUnavailable"
        case .writing, .response: return nil
        }
    }

    public static let sources: Set<String> = ["phone.camera", "phone.microphone", "phone.bluetooth"]
    public static func audio(_ frame: MicrophoneFrame, sessionID: String, sequence: UInt64? = nil) throws -> AgentInput
    {
        let audio = try AudioInput(
            samples: frame.samples.withUnsafeBytes { Data($0) }, sampleRate: frame.sampleRate,
            sequence: sequence ?? frame.sequence, timestamp: frame.timestamp,
            layout: frame.layout == .mono ? .mono : .firstOrderAmbisonicsACNSN3D, capturedAt: frame.capturedAt)
        return try envelope(.audio(audio), source: "phone.microphone", sessionID: sessionID, lifetime: .seconds(60))
    }
    public static func image(_ frame: CameraFrame, sessionID: String) throws -> AgentInput {
        let image = try ImageInput(
            width: frame.width, height: frame.height, attachment: ImageValueAttachment(frame),
            sequence: frame.sequence, timestamp: frame.timestamp, rotation: frame.rotation, capturedAt: frame.capturedAt
        )
        return try envelope(.image(image), source: "phone.camera", sessionID: sessionID, lifetime: .seconds(1))
    }
    public static func executionAttachment(_ image: ImageInput?, sequence: UInt64) throws -> (any Sendable)? {
        guard let image else { return nil }
        guard case .attachment(let value) = image.content,
            let native = value as? ImageValueAttachment<CameraFrame>,
            native.value.sequence == sequence, image.sequence == sequence,
            native.value.width == image.width, native.value.height == image.height,
            native.value.rotation == image.rotation, native.value.timestamp == image.timestamp,
            native.value.capturedAt == image.capturedAt,
            native.value.capturedAt.duration(to: .now) >= .zero,
            native.value.capturedAt.duration(to: .now) < .milliseconds(750)
        else { throw CommunicationError.expired }
        return native.value
    }
    public static func bluetooth(_ snapshot: NexArmBluetoothSnapshot) throws -> AgentInput {
        let data = try JSONSerialization.data(withJSONObject: [
            "revision": snapshot.revision, "phase": String(describing: snapshot.phase),
            "power": String(describing: snapshot.power), "scanning": snapshot.scanning,
            "failure": snapshot.failure.map { String(describing: $0) } ?? "",
        ])
        return try envelope(
            .event(String(decoding: data, as: UTF8.self)), source: "phone.bluetooth",
            sessionID: snapshot.connectionID, lifetime: .seconds(1))
    }
    public static func audioEvent(_ event: NativeAudioEvent, sessionID: String) throws -> AgentInput {
        try envelope(
            .event(event.rawValue), source: "phone.microphone", sessionID: sessionID, lifetime: .seconds(1))
    }
    public static func cameraEvent(_ event: CameraEvent, sessionID: String) throws -> AgentInput {
        try envelope(.event(event.rawValue), source: "phone.camera", sessionID: sessionID, lifetime: .seconds(1))
    }
    private static func envelope(
        _ payload: InputPayload, source: String, sessionID: String, lifetime: Duration
    ) throws -> AgentInput {
        try ExternalInputAdapter.signal(
            ExternalInputDraft(
                sessionID: sessionID, payload: payload, source: source, deadline: .now.advanced(by: lifetime)))
    }
}

/// One joined native input connection; no per-frame task or unbounded waiting queue.
public actor DeviceInputConnection {
    private let task: Task<Void, any Error>
    public init(
        frames: AsyncThrowingStream<CameraFrame, any Error>, sessionID: String, input: InputGateway
    ) {
        task = Task {
            for try await frame in frames {
                try Task.checkCancellation()
                try await input.publish(DeviceInputAdapter.image(frame, sessionID: sessionID))
            }
            try Task.checkCancellation()
        }
    }
    public func wait() async throws {
        let task = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    public func stop() async {
        task.cancel()
        _ = await task.result
    }
    deinit { task.cancel() }
}
