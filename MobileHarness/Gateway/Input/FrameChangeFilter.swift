import AgentCore
import Foundation

public struct FrameChangeConfiguration: Sendable {
    public let minimumChange: Double
    public let minimumInterval: TimeInterval
    public init(minimumChange: Double = 0.03, minimumInterval: TimeInterval = 0) throws {
        guard minimumChange.isFinite, (0...1).contains(minimumChange),
            minimumInterval.isFinite, (0...1).contains(minimumInterval)
        else { throw ImageInputError.invalidFrame }
        self.minimumChange = minimumChange
        self.minimumInterval = minimumInterval
    }
}

/// Fixed 64x64 grayscale comparison. The baseline is the previous examined frame,
/// including rejected frames; interval-skipped frames do not change the baseline.
public struct FrameChangeFilter: Sendable {
    private let configuration: FrameChangeConfiguration
    private var previous: [UInt8]?
    private var geometry: [Int]?
    private var lastSequence: UInt64?
    private var lastTimestamp: TimeInterval?
    private var examinedAt: TimeInterval?
    public init(configuration: FrameChangeConfiguration) { self.configuration = configuration }
    public mutating func accepts(_ frame: ImageInput) throws -> Bool {
        guard lastSequence.map({ frame.sequence > $0 }) ?? true,
            lastTimestamp.map({ frame.timestamp >= $0 }) ?? true
        else { throw ImageInputError.outOfOrder }
        lastSequence = frame.sequence
        lastTimestamp = frame.timestamp
        let shape = [frame.width, frame.height, frame.rotation]
        let changedGeometry = geometry != shape
        if !changedGeometry, let examinedAt, frame.timestamp - examinedAt < configuration.minimumInterval {
            return false
        }
        var gray = [UInt8](repeating: 0, count: 64 * 64)
        frame.rgb.withUnsafeBytes { data in
            let pixels = data.bindMemory(to: UInt8.self)
            for y in 0..<64 {
                let sy = min(frame.height - 1, (2 * y + 1) * frame.height / 128)
                for x in 0..<64 {
                    let sx = min(frame.width - 1, (2 * x + 1) * frame.width / 128)
                    let i = (sy * frame.width + sx) * 3
                    gray[y * 64 + x] = UInt8(
                        (77 * Int(pixels[i]) + 150 * Int(pixels[i + 1]) + 29 * Int(pixels[i + 2]) + 128) >> 8)
                }
            }
        }
        defer {
            previous = gray
            geometry = shape
            examinedAt = frame.timestamp
        }
        guard !changedGeometry, let previous else { return true }
        let difference = zip(gray, previous).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        // Even a zero threshold never repeatedly infers an identical image.
        return difference > 0 && Double(difference) / (255 * 4096) >= configuration.minimumChange
    }
}

/// One session/filter and one active submit. No image queue in the Gateway.
public actor CameraInputSession {
    private let gateway: InputGateway
    private let sessionID: UUID
    private var filter: FrameChangeFilter
    private var busy = false
    public init(gateway: InputGateway, sessionID: UUID, configuration: FrameChangeConfiguration) {
        self.gateway = gateway
        self.sessionID = sessionID
        filter = FrameChangeFilter(configuration: configuration)
    }
    @discardableResult
    public func submit(_ frame: ImageInput) async throws -> Bool {
        try Task.checkCancellation()
        guard !busy else { throw HarnessError.queueFull }
        busy = true
        defer { busy = false }
        guard try filter.accepts(frame) else { return false }
        let report = try await gateway.submit(
            AgentInput(sessionID: sessionID, payload: .image(frame)), to: .photographer)
        guard report.delivered == [.photographer], report.rejected.isEmpty else { throw HarnessError.notRunning }
        return true
    }
}
