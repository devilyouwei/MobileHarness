import Foundation

/// Bounded playback facts shared by the two speech roles; times describe native scheduling, not acoustic arrival.
public struct SpeechPlaybackSnapshot: Sendable {
    struct Period: Sendable {
        let id: String
        let sessionID: String
        let start: ContinuousClock.Instant
        var end: ContinuousClock.Instant?
    }
    var periods: [Period] = []
    var retainedSince: ContinuousClock.Instant?
    public init() {}

    func state(at time: ContinuousClock.Instant) -> (playing: Bool, known: Bool) {
        if let retainedSince, time < retainedSince { return (false, false) }
        for period in periods.reversed() where time >= period.start {
            if let end = period.end,
                time >= end.advanced(by: .milliseconds(200))
            {
                continue
            }
            return (true, true)
        }
        return (false, true)
    }
}

struct SpeechPlaybackHistory: Sendable {
    private var snapshot = SpeechPlaybackSnapshot()
    mutating func started(id: String, sessionID: String, at time: ContinuousClock.Instant) {
        if snapshot.periods.last?.id == id { return }
        if let last = snapshot.periods.last, time < last.start { return }
        if let index = snapshot.periods.indices.last, snapshot.periods[index].end == nil {
            snapshot.periods[index].end = time
        }
        snapshot.periods.append(.init(id: id, sessionID: sessionID, start: time))
        if snapshot.periods.count > 32 {
            snapshot.periods.removeFirst()
            snapshot.retainedSince = snapshot.periods.first?.start
        }
    }
    mutating func ended(id: String, at time: ContinuousClock.Instant) {
        guard let index = snapshot.periods.indices.last, snapshot.periods[index].id == id,
            snapshot.periods[index].end == nil, time >= snapshot.periods[index].start
        else { return }
        snapshot.periods[index].end = time
    }
    func read(sessionID: String) -> SpeechPlaybackSnapshot {
        var result = snapshot
        result.periods = result.periods.filter { $0.sessionID == sessionID }
        return result
    }
}
