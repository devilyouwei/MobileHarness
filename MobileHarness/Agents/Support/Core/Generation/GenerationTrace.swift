import Foundation

/// Dry-run observation before Gateway dispatch. Parser failure never discards model text.
public struct GenerationTrace: Sendable {
    public static let maximumBytes = 256 * 1024
    public static let maximumFragments = 8192
    public private(set) var raw = ""
    public private(set) var fragments: [String] = []
    public private(set) var events: [GenerationEvent] = []
    public var calls: [ActionCall] {
        events.compactMap(\.actionCall)
    }
    public private(set) var parserError: String?
    public private(set) var finished = false
    private var closed = false
    private var generator: AgentGenerator

    public init(
        capabilities: CapabilityRegistry, textMapping: AgentGenerator.TextMapping? = nil,
        segmentation: TextSegmentationPolicy = .sentences
    ) {
        generator = AgentGenerator(capabilities: capabilities, textMapping: textMapping, segmentation: segmentation)
    }

    public mutating func append(_ delta: String) throws {
        guard !closed else { throw GenerationError.closed }
        guard raw.utf8.count + delta.utf8.count <= Self.maximumBytes,
            fragments.count < Self.maximumFragments
        else {
            closed = true
            throw GenerationError.limitExceeded
        }
        raw += delta
        fragments.append(delta)
        guard parserError == nil else { return }
        do { events += try generator.append(delta) } catch {
            parserError = "fragment \(fragments.count): \(error)"
        }
    }

    /// Call only after a normal stream end with a completion event, never on cancellation/failure.
    public mutating func finish() {
        guard !closed else { return }
        closed = true
        finished = true
        guard parserError == nil else { return }
        do { events += try generator.finish() } catch {
            parserError = "finish: \(error)"
        }
    }
}
