import CoreGraphics
import Foundation
import Testing

@testable import UI

@MainActor private func requestedDeparture(_ value: PhotoDeparture) async throws -> PhotoDeparture.Request {
    for _ in 0..<1000 {
        if let request = value.request { return request }
        await Task.yield()
    }
    return try #require(value.request)
}

@Test @MainActor func photoDepartureRequiresTheMatchingRendererAcknowledgment() async throws {
    let departure = PhotoDeparture()
    departure.setAvailable(true)
    let task = Task { try await departure.perform(.save) }
    defer { task.cancel() }
    let request = try await requestedDeparture(departure)
    #expect(request.kind == .save)
    #expect(UUID(uuidString: request.id) != nil)
    departure.complete(id: UUID().uuidString, success: true)
    #expect(departure.request == request)
    departure.complete(id: request.id, success: true)
    try await task.value
    departure.complete(id: request.id, success: false)
    #expect(departure.request == nil)
    await #expect(throws: PhotoDeparture.Failure.self) { try await departure.perform(.discard) }
}

@Test @MainActor func photoDepartureDisappearanceAndCancellationReleaseRendererWait() async throws {
    let unavailable = PhotoDeparture()
    await #expect(throws: PhotoDeparture.Failure.self) { try await unavailable.perform(.save) }
    unavailable.setAvailable(true)
    let hidden = Task { try await unavailable.perform(.discard) }
    defer { hidden.cancel() }
    _ = try await requestedDeparture(unavailable)
    unavailable.setAvailable(false)
    await #expect(throws: PhotoDeparture.Failure.self) { try await hidden.value }
    #expect(unavailable.request == nil)

    let departure = PhotoDeparture()
    departure.setAvailable(true)
    let cancelled = Task { try await departure.perform(.save) }
    defer { cancelled.cancel() }
    let request = try await requestedDeparture(departure)
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    departure.complete(id: request.id, success: true)
    #expect(departure.request == nil)
}

@Test(arguments: [CGSize(width: 320, height: 568), CGSize(width: 402, height: 874), CGSize(width: 874, height: 402)])
func photoDepartureLeavesBothScreenEdgesAndSaveNeverShrinks(_ size: CGSize) {
    let enlarged = PhotoDepartureLayout.pose(size: size, bottomInset: 34, kind: .save, phase: .enlarged)
    let saved = PhotoDepartureLayout.pose(size: size, bottomInset: 34, kind: .save, phase: .exited)
    #expect(enlarged.scale == 1.16 && saved.scale == enlarged.scale)
    #expect(saved.center.y == enlarged.center.y)
    #expect(saved.center.x - 96 * saved.scale / 2 > size.width)
    let discarded = PhotoDepartureLayout.pose(size: size, bottomInset: 34, kind: .discard, phase: .exited)
    #expect(discarded.scale == 0.06)
    #expect(discarded.center.x - 96 * discarded.scale / 2 > size.width)
    #expect(discarded.center.y - 128 * discarded.scale / 2 > size.height)
}
