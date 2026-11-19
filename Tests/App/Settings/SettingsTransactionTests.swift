import Actions
import Agents
import Foundation
import Gateway
import PlatformKit
import Testing

@testable import UI

@MainActor
private final class SettingsFacadeFixture {
    var value = CloudSettingsDraft(enabled: true, url: "https://example.invalid", key: "fixture", model: "old")
    var restores = 0
    var failSave = false
    @available(macOS 27, iOS 27, *)
    func workflow() -> ProviderSettingsClient {
        ProviderSettingsClient(
            provider: .init(
                initial: value,
                restore: {
                    self.restores += 1
                    return self.value
                }, discover: { _ in [] },
                save: { draft in
                    if self.failSave { throw CancellationError() }
                    self.value = draft
                }, errorMessage: { _ in nil }))
    }
}
@available(macOS 27, iOS 27, *)
@Test(arguments: [false, true]) @MainActor
func settingsFacadeCommitsOnlyAcknowledgedSaveAndReconcilesFailure(fails: Bool) async throws {
    let fixture = SettingsFacadeFixture()
    let workflow = fixture.workflow()
    _ = try await workflow.restore()
    fixture.failSave = fails
    let updated = CloudSettingsDraft(enabled: true, url: "https://example.invalid", key: "fixture", model: "new")
    if fails {
        await #expect(throws: (any Error).self) { try await workflow.save(updated) }
    } else {
        try await workflow.save(updated)
    }
    let confirmed = fails ? "old" : "new"
    #expect(workflow.modelName == confirmed)
    #expect(try await workflow.restore().model == confirmed)
    #expect(fixture.restores == (fails ? 2 : 1))
}
