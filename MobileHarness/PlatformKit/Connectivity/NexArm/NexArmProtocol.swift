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
