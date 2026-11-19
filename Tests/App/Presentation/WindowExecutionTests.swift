import Actions
import Foundation
import FunctionContracts
import Testing
import UI

@MainActor private final class WindowLifecycleProbe: WindowContentLifecycle {
    var events: [String] = []
    var fails = false
    var transitioning = false
    func beginWindowTransition() async throws { transitioning = true }
    func endWindowTransition() { transitioning = false }
    func pauseWindow(invocation: any FunctionInput) async throws {
        events.append("pause")
        if fails { throw WindowError.busy }
    }
    func resumeWindow(invocation: any FunctionInput) async throws {
        events.append("resume")
        if fails { throw WindowError.unavailable }
    }
    func closeWindow(invocation: any FunctionInput) async throws {
        events.append("close")
        if fails { throw WindowError.busy }
    }
}
private func windowInput(_ operation: String = "minimize", parameters: [String: String] = [:]) -> FunctionInvocation {
    .init(
        call: .init(actionPath: .init(domain: "UI", module: "Window", function: operation), parameters: parameters),
        context: .init(source: "applicationControl", sessionID: "fixture", inputID: UUID().uuidString),
        executionID: UUID().uuidString, results: ActionReportStore())
}
@MainActor private func awaitWindow(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw WindowError.unavailable }
        await Task.yield()
    }
}
@MainActor private func windowFixture(_ state: WindowState, content: String) async throws -> UUID {
    let task = Task { try await state.present(content: .init(rawValue: content), title: content) }
    try await awaitWindow { state.windows.contains { $0.content == content } }
    let item = try #require(state.windows.first { $0.content == content })
    state.complete(item.id, revision: item.revision, generation: state.generation, success: true)
    return try await task.value
}
@Test @MainActor func windowLifecycleFailureRetainsWindowAndResumeWaitsForPresentation() async throws {
    let state = WindowState()
    state.layout(width: 390, height: 750)
    state.setAvailable(true)
    let id = try await windowFixture(state, content: "fixture")
    let probe = WindowLifecycleProbe()
    let service = WindowExecutionService(state: state, lifecycles: ["fixture": probe])
    probe.fails = true
    await #expect(throws: WindowExecutionFailure.self) {
        try await service.performWindow(
            .minimize, id: try #require(state.reference(for: id)), x: nil, y: nil, invocation: windowInput())
    }
    #expect(try state.find(id).mode == .normal)
    #expect(!probe.transitioning)
    probe.fails = false
    let minimize = Task {
        try await service.performWindow(
            .minimize, id: try #require(state.reference(for: id)), x: nil, y: nil, invocation: windowInput())
    }
    try await awaitWindow { (try? state.find(id).mode) == .minimized }
    let item = try state.find(id)
    state.complete(id, revision: item.revision, generation: state.generation, success: true)
    try await minimize.value
    let restore = Task {
        try await service.performWindow(
            .restore, id: try #require(state.reference(for: id)), x: nil, y: nil, invocation: windowInput())
    }
    try await awaitWindow { (try? state.find(id).mode) == .normal }
    #expect(!probe.events.contains("resume"))
    #expect(probe.transitioning)
    let restored = try state.find(id)
    state.complete(id, revision: restored.revision, generation: state.generation, success: true)
    try await restore.value
    #expect(probe.events.last == "resume")
    #expect(!probe.transitioning)
    probe.fails = true
    await #expect(throws: WindowExecutionFailure.self) {
        try await service.performWindow(
            .close, id: try #require(state.reference(for: id)), x: nil, y: nil, invocation: windowInput())
    }
    #expect(try state.find(id).phase == .settled)
    await service.stop()
    await state.stop()
}
@Test @MainActor func windowActionValidationAndClosePreemptsOnlyItsOwnTransition() async throws {
    let state = WindowState()
    state.layout(width: 390, height: 750)
    state.setAvailable(true)
    let first = try await windowFixture(state, content: "one")
    let second = try await windowFixture(state, content: "two")
    let service = WindowExecutionService(state: state, lifecycles: [:])
    await #expect(throws: (any Error).self) {
        try await WindowActions.move(
            invocation: windowInput(
                "move", parameters: ["windowID": try #require(state.reference(for: first)), "x": "nan", "y": "0"]),
            using: service)
    }
    let a = Task {
        try await service.performWindow(
            .maximize, id: try #require(state.reference(for: first)), x: nil, y: nil, invocation: windowInput())
    }
    let b = Task {
        try await service.performWindow(
            .maximize, id: try #require(state.reference(for: second)), x: nil, y: nil, invocation: windowInput())
    }
    try await awaitWindow { state.windows.allSatisfy { $0.mode == .maximized } }
    let closing = Task {
        try await service.performWindow(
            .close, id: try #require(state.reference(for: first)), x: nil, y: nil, invocation: windowInput())
    }
    try await awaitWindow { (try? state.find(first).phase) == .closing }
    await #expect(throws: (any Error).self) { try await a.value }
    #expect(try state.find(second).phase == .changing)
    for id in [first, second] {
        let item = try state.find(id)
        state.complete(id, revision: item.revision, generation: state.generation, success: true)
    }
    try await closing.value
    try await b.value
    #expect(state.windows.count == 1 && state.windows.first?.id == second)
    await service.stop()
    await state.stop()
}

@Test @MainActor func windowReferencesExposeReadableAliasesAndNeverResolveUUIDs() async throws {
    let state = WindowState()
    state.layout(width: 390, height: 750)
    state.setAvailable(true)
    let first = try await windowFixture(state, content: "one")
    let second = try await windowFixture(state, content: "two")
    #expect(state.reference(for: first) == "window_1")
    #expect(state.reference(for: second) == "window_2")
    #expect(try state.resolve(reference: "window_2") == second)
    await #expect(throws: WindowError.busy) {
        try await state.present(content: .artifact, title: "Duplicate", windowID: first)
    }
    #expect(state.reference(for: first) == "window_1")
    #expect(throws: WindowError.missing) { try state.resolve(reference: first.uuidString) }
    let snapshot = try await state.stateSnapshot()
    let text = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    #expect(text.contains("window_1") && !text.contains(first.uuidString) && !text.contains(second.uuidString))
    await state.stop()
}
