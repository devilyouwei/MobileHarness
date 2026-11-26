import Foundation

/// Same-session playback facts using offsets from a process-wide monotonic clock origin.
public struct SpeechPlaybackSnapshot: Codable, Sendable, Equatable {
    struct Period: Codable, Sendable, Equatable {
        let start: Duration
        let end: Duration?
    }
    fileprivate static let maximumPeriods = 32
    let periods: [Period]
    let retainedSince: Duration?

    public init() { self.init(periods: [], retainedSince: nil) }

    fileprivate init(periods: [Period], retainedSince: Duration?) {
        self.periods = periods
        self.retainedSince = retainedSince
    }

    static func offset(at instant: ContinuousClock.Instant) -> Duration {
        SpeechSignalClock.offset(at: instant)
    }

    var isValid: Bool {
        guard periods.count <= Self.maximumPeriods else { return false }
        var previousStart = retainedSince
        for (index, period) in periods.enumerated() {
            if let previousStart, period.start < previousStart { return false }
            if let end = period.end {
                guard period.start <= end else { return false }
            } else if index != periods.count - 1 {
                return false
            }
            previousStart = period.start
        }
        return true
    }
}

struct SpeechPlaybackHistory: Sendable {
    private struct Entry: Sendable {
        let id: String
        let sessionID: String
        let start: ContinuousClock.Instant
        var end: ContinuousClock.Instant?
    }
    private var entries: [Entry] = []
    private var retainedSince: ContinuousClock.Instant?

    mutating func started(id: String, sessionID: String, at time: ContinuousClock.Instant) {
        if entries.last?.id == id { return }
        if let last = entries.last, time < last.start { return }
        if let index = entries.indices.last, entries[index].end == nil {
            entries[index].end = time
        }
        entries.append(.init(id: id, sessionID: sessionID, start: time))
        if entries.count > SpeechPlaybackSnapshot.maximumPeriods {
            entries.removeFirst()
            retainedSince = entries.first?.start
        }
    }

    mutating func ended(id: String, at time: ContinuousClock.Instant) {
        guard let index = entries.indices.last, entries[index].id == id,
            entries[index].end == nil, time >= entries[index].start
        else { return }
        entries[index].end = time
    }

    func read(sessionID: String) -> SpeechPlaybackSnapshot {
        let periods = entries.filter { $0.sessionID == sessionID }.map {
            SpeechPlaybackSnapshot.Period(
                start: SpeechPlaybackSnapshot.offset(at: $0.start), end: $0.end.map(SpeechPlaybackSnapshot.offset(at:)))
        }
        return SpeechPlaybackSnapshot(
            periods: periods, retainedSince: retainedSince.map(SpeechPlaybackSnapshot.offset(at:)))
    }
}
