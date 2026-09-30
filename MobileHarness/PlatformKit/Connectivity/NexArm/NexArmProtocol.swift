import Foundation

public enum NexArmError: Error, Equatable, Sendable {
    case invalidPacket, overflow, timeout, busy, disconnected
    case io(Int32)
    case unsupportedFirmware, firmwareUnavailable, invalidMotion, alreadyUsed, moving, uncertainMotion
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
    /// Narrow live-control allowlist: finite servo positions, bounded settings poses, or explicit reset.
    public var isObservedControl: Bool {
        (id == 255 && ((command == 11 && payload.isEmpty) || (command == 8 && payload.count == 14)))
            || isHeadControl
    }
    private var isHeadControl: Bool {
        guard id == 4 || id == 5, command == 3, payload.count == 8,
            payload[0] == 41, payload[1] == 30, payload[4] == 0, payload[5] == 0
        else { return false }
        let position = Int(payload[2]) | Int(payload[3]) << 8
        let speed = Int(payload[6]) | Int(payload[7]) << 8
        return NexArmJogPlanner.limits[Int(id) - 1].contains(position) && speed == 1400
    }
    public var isLiveControl: Bool {
        if isHeadControl { return true }
        if id == 255 && command == 54 { return payload.count == 2 }
        if id == 255 && command == 8 && payload.count == 14 {
            let v = stride(from: 0, to: 14, by: 2).map {
                Int(Int16(bitPattern: UInt16(payload[$0]) | UInt16(payload[$0 + 1]) << 8))
            }
            return v[0] == 0 && hypot(Double(v[1]), Double(v[2])) <= 450
                && (50...600).contains(v[3]) && abs(v[4]) <= 45 && v[5] == 0
                && (400...800).contains(v[6])
        }
        guard (1...6).contains(id), command == 3, payload.count == 8,
            payload[0] == 41, payload[1] == 30, payload[4] == 0, payload[5] == 0
        else { return false }
        let position = Int(payload[2]) | Int(payload[3]) << 8
        let speed = Int(payload[6]) | Int(payload[7]) << 8
        return (0...4095).contains(position) && (1...600).contains(speed)
    }
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

/// Host observation watchdog. Receipt timestamps are not device sampling timestamps.
public struct NexArmArrivalTracker: Sendable {
    public enum Outcome: Sendable, Equatable { case waiting, arrived, feedbackTimeout, completionTimeout }
    /// Each awaited segment needs its own bounded settling/observation allowance.
    public static func completionBudget(durationMilliseconds: Int) -> Duration {
        .milliseconds(durationMilliseconds + 3000)
    }
    private let target: [Int]
    private let jointTarget: [Int]?
    private let final: Bool
    private let started: ContinuousClock.Instant
    private let deadline: ContinuousClock.Instant
    private let earliestObservation: ContinuousClock.Instant
    private var lastFeedback: ContinuousClock.Instant
    private var stableSince: ContinuousClock.Instant?
    private var anchor: [Int]?
    public init(
        target: [Int], final: Bool, started: ContinuousClock.Instant, durationMilliseconds: Int,
        actionDeadline: ContinuousClock.Instant? = nil, jointTarget: [Int]? = nil,
        minimumObservationMilliseconds: Int = 0
    ) {
        self.target = target
        self.jointTarget = jointTarget
        self.final = final
        self.started = started
        // Stable early feedback can describe a stationary start or an intermediate plateau
        // while firmware still owns the trajectory. Never hand off before its nominal end.
        earliestObservation = started.advanced(
            by: .milliseconds(max(durationMilliseconds, minimumObservationMilliseconds)))
        let segmentDeadline = started.advanced(by: Self.completionBudget(durationMilliseconds: durationMilliseconds))
        deadline = min(segmentDeadline, actionDeadline ?? segmentDeadline)
        lastFeedback = started
    }
    public mutating func observe(pose: [Int], joints: [Int], at time: ContinuousClock.Instant) {
        guard pose.count == 6, target.count == 6, joints.count == 6, time >= started, time >= lastFeedback else {
            return
        }
        lastFeedback = time
        let poseArrived =
            zip(pose.prefix(3), target.prefix(3)).allSatisfy { abs($0 - $1) <= (final ? 5 : 15) }
            && abs(pose[3] - target[3]) <= (final ? 20 : 40)
            && abs(pose[4] - target[4]) <= 2 && abs(pose[5] - target[5]) <= 2
        let arrived =
            jointTarget.map { target in
                target.count == 6 && zip(joints, target).allSatisfy { abs($0 - $1) <= 16 }
            } ?? poseArrived
        guard arrived else {
            stableSince = nil
            anchor = nil
            return
        }
        if let anchor, zip(joints, anchor).allSatisfy({ abs($0 - $1) <= 2 }) { return }
        anchor = joints
        stableSince = time
    }
    public func outcome(at time: ContinuousClock.Instant) -> Outcome {
        if time >= deadline { return .completionTimeout }
        if time - lastFeedback >= .seconds(2) { return .feedbackTimeout }
        // Only received samples can advance the stable window, never wall-clock waiting alone.
        if lastFeedback >= earliestObservation, let stableSince,
            lastFeedback - stableSince >= .milliseconds(final ? 300 : 200)
        {
            return .arrived
        }
        return .waiting
    }
}
