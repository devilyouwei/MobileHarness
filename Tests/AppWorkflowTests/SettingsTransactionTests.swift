import Foundation
import Testing
import UI

@testable import AppSettingsWorkflow

private enum ProviderFixtureError: Error { case invalid, application }
@MainActor
private final class SettingsTransactionFixture: SettingsPersistence {
    var value: CloudSettings? = .init(enabled: false, url: "https://example.invalid", key: "fixture", model: "old")
    var events: [String] = []
    func load() async throws -> CloudSettings? { value }
    func save(_ value: CloudSettings?) async throws {
        events.append("persist:\(value?.model ?? "nil")")
        self.value = value
    }
    var provider: SettingsProviderOperations {
        SettingsProviderOperations(
            initial: .init(enabled: false, url: "https://example.invalid", key: "", model: "default"),
            prepare: { draft in
                self.events.append("prepare:\(draft?.model ?? "nil")")
                if draft?.model == "invalid" { throw ProviderFixtureError.invalid }
                return {
                    self.events.append("apply:\(draft?.model ?? "nil")")
                    if draft?.model == "new" { throw ProviderFixtureError.application }
                }
            }, discover: { _ in [] }, errorMessage: { _ in nil })
    }
    @available(macOS 27, iOS 27, *)
    func workflow() -> SettingsWorkflow {
        SettingsWorkflow(
            provider: provider, store: self,
            beginChange: { self.events.append("begin") }, endChange: { self.events.append("end") })
    }
}

@Test @MainActor
func settingsProviderFailureRollsBackBeforeReleasingChangeBarrier() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let fixture = SettingsTransactionFixture()
    let workflow = fixture.workflow()
    _ = try await workflow.restore()
    fixture.events.removeAll()
    await #expect(throws: (any Error).self) {
        try await workflow.save(.init(enabled: true, url: "https://example.invalid", key: "fixture", model: "new"))
    }
    #expect(fixture.events == ["prepare:new", "begin", "persist:new", "apply:new", "persist:old", "end"])
    #expect(fixture.value?.model == "old")
    // A failed apply must also leave the workflow's committed snapshot unchanged.
    #expect(try await workflow.restore().model == "old")
}

@Test @MainActor
func settingsProviderValidationFailsBeforePersistenceOrChangeBarrier() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let fixture = SettingsTransactionFixture()
    let workflow = fixture.workflow()
    _ = try await workflow.restore()
    fixture.events.removeAll()
    await #expect(throws: (any Error).self) {
        try await workflow.save(.init(enabled: true, url: "https://example.invalid", key: "fixture", model: "invalid"))
    }
    #expect(fixture.events == ["prepare:invalid"])
    #expect(fixture.value?.model == "old")
}
