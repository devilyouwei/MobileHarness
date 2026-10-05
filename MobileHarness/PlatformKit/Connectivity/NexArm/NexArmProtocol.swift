import Foundation

public enum NexArmError: Error, Equatable, Sendable {
    case invalidPacket, overflow, timeout, busy, disconnected, sessionReplaced
    case io(Int32)
    case invalidMotion
}

public struct NexArmPacket: Equatable, Sendable {
    public let id: UInt8
    public let command: UInt8
    public let payload: [UInt8]

    public init(id: UInt8 = 0xFF, command: UInt8, payload: [UInt8] = []) throws {
        guard payload.count <= 253 else { throw NexArmError.invalidPacket }
        self.id = id
        self.command = command
        self.payload = payload
    }
    /// Observation sessions admit supported addressed position writes and read-only telemetry requests.
    public var isObservedControl: Bool {
        (id == 255 && command == 11 && payload.isEmpty) || isSynchronousPositionWrite || isSinglePositionWrite
    }
    public var isSynchronousPositionWrite: Bool {
        guard id == 254, command == 131, (10...50).contains(payload.count), (payload.count - 2) % 8 == 0,
            payload[0] == 41, payload[1] == 7
        else { return false }
        var motors: Set<UInt8> = []
        for start in stride(from: 2, to: payload.count, by: 8) {
            guard (1...6).contains(payload[start]), motors.insert(payload[start]).inserted,
                (1...254).contains(payload[start + 1]),
                payload[start + 4] == 0, payload[start + 5] == 0
            else { return false }
            let target = Int(payload[start + 2]) | Int(payload[start + 3]) << 8
            let speed = Int(payload[start + 6]) | Int(payload[start + 7]) << 8
            guard NexArmMotorCommands.positionLimits[Int(payload[start]) - 1].contains(target),
                (1...1400).contains(speed)
            else {
                return false
            }
        }
        return true
    }
    private var isSinglePositionWrite: Bool {
        guard (1...6).contains(id), command == 3, payload.count == 8,
            payload[0] == 41, (1...254).contains(payload[1]), payload[4] == 0, payload[5] == 0
        else { return false }
        let position = Int(payload[2]) | Int(payload[3]) << 8
        let speed = Int(payload[6]) | Int(payload[7]) << 8
        return NexArmMotorCommands.positionLimits[Int(id) - 1].contains(position) && (1...1400).contains(speed)
    }
    public var motorTargets: [Int: Int]? {
        if isSynchronousPositionWrite {
            return Dictionary(
                uniqueKeysWithValues: stride(from: 2, to: payload.count, by: 8).map { offset in
                    return (Int(payload[offset]), Int(payload[offset + 2]) | Int(payload[offset + 3]) << 8)
                })
        }
        if isSinglePositionWrite { return [Int(id): Int(payload[2]) | Int(payload[3]) << 8] }
        return nil
    }
    public var isLiveControl: Bool { isSinglePositionWrite || isSynchronousPositionWrite }
    public var bytes: [UInt8] {
        let body = [id, UInt8(payload.count + 2), command] + payload
        return [0xFF, 0xFF] + body + [~body.reduce(0, &+)]
    }
}

/// Bounded resynchronizing decoder for mixed ESP32 text logs and binary frames.
public struct NexArmDecoder: Sendable {
    private var buffer: [UInt8] = []
    public init() {}
    public mutating func append(_ bytes: [UInt8]) throws {
        guard buffer.count + bytes.count <= 4096 else { throw NexArmError.overflow }
        buffer += bytes
    }
    public mutating func next() throws -> NexArmPacket? {
        while buffer.count >= 4 {
            guard buffer[0] == 255, buffer[1] == 255, buffer[3] >= 2 else {
                buffer.removeFirst()
                continue
            }
            let count = Int(buffer[3]) + 4
            guard buffer.count >= count else { return nil }
            let bytes = Array(buffer.prefix(count))
            guard bytes.dropFirst(2).reduce(UInt8(0), &+) == 255 else {
                buffer.removeFirst()
                continue
            }
            buffer.removeFirst(count)
            return try NexArmPacket(id: bytes[2], command: bytes[4], payload: Array(bytes[5..<(count - 1)]))
        }
        return nil
    }
}

public protocol NexArmLink: Actor {
    func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) async throws
        -> NexArmPacket
    func close() async
}

/// Write acknowledgment only; callers must separately verify physical completion.
public protocol NexArmWritableLink: NexArmLink {
    func write(_ packet: NexArmPacket) async throws
}

/// Latest valid pose only; older telemetry is replaceable, never an action queue.
public struct NexArmTelemetry: Sendable {
    public let sequence: UInt64
    public let receivedAt: ContinuousClock.Instant
    public let packet: NexArmPacket
}
public struct NexArmTelemetryCache: Sendable {
    private var decoder = NexArmDecoder()
    private var sequence: UInt64 = 0
    public private(set) var latest: NexArmTelemetry?
    public init() {}
    public mutating func receive(_ bytes: [UInt8], at time: ContinuousClock.Instant = .now) throws {
        try decoder.append(bytes)
        while let packet = try decoder.next() {
            guard packet.id == 255, packet.command == 11, packet.payload.count == 24 else { continue }
            let p = packet.payload
            guard stride(from: 12, to: 24, by: 2).allSatisfy({ (Int(p[$0]) | Int(p[$0 + 1]) << 8) <= 4095 }) else {
                continue
            }
            sequence &+= 1
            latest = NexArmTelemetry(sequence: sequence, receivedAt: time, packet: packet)
        }
    }
}

/// Observation sessions are fenced by live/manual takeover and disconnect.
public protocol NexArmObservableLink: NexArmWritableLink {
    func beginObservation() async throws -> UUID
    func sendObserved(_ packet: NexArmPacket, session: UUID) async throws -> Bool
    func latestObservation(after sequence: UInt64, session: UUID) async throws -> NexArmTelemetry?
    func endObservation(_ session: UUID) async
}

/// Connection-level health counts fresh receipts even when all positions are unchanged.
public struct NexArmFeedbackWatchdog: Sendable {
    private var lastReceipt: ContinuousClock.Instant
    public init(started: ContinuousClock.Instant) { lastReceipt = started }
    public mutating func observe(at receipt: ContinuousClock.Instant) {
        if receipt > lastReceipt { lastReceipt = receipt }
    }
    public func isLost(at now: ContinuousClock.Instant) -> Bool { now - lastReceipt >= .seconds(2) }
}
