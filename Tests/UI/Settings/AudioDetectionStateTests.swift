import Foundation
import Testing

@testable import UI

@Test @MainActor func audioDetectionExpiresDirectionAndDetectsMissingPCMIndependently() {
    let state = AudioDetectionState()
    let now = ContinuousClock.now
    state.snapshot.capturedAt = now
    state.snapshot.signal = .receiving
    state.snapshot.level = 0.8
    state.snapshot.direction = .active
    state.snapshot.azimuthDegrees = 90
    state.snapshot.elevationDegrees = 10
    state.snapshot.directionExpiresAt = now.advanced(by: .milliseconds(500))
    state.refresh(at: now.advanced(by: .milliseconds(501)))
    #expect(state.snapshot.azimuthDegrees == nil && state.snapshot.elevationDegrees == nil)
    #expect(state.snapshot.direction == .waiting)
    #expect(state.snapshot.signal == .receiving && state.snapshot.level == 0.8)
    state.refresh(at: now.advanced(by: .milliseconds(1001)))
    #expect(state.snapshot.signal == .noAudio && state.snapshot.level == 0)
}

@Test @MainActor func audioDetectionUnavailableRemainsExplicitAfterStop() {
    let state = AudioDetectionState()
    state.snapshot.direction = .unavailable
    state.clearDirection()
    #expect(state.snapshot.direction == .unavailable)
    #expect(state.snapshot.directionExpiresAt == nil)
}

@Test @MainActor func audioDetectionRetainsQuietStatusWithoutRetainingDirection() {
    let state = AudioDetectionState()
    state.snapshot.direction = .inactive
    state.snapshot.directionExpiresAt = .now.advanced(by: .milliseconds(-1))
    state.refresh()
    #expect(state.snapshot.direction == .inactive)
    #expect(state.snapshot.azimuthDegrees == nil)
}
