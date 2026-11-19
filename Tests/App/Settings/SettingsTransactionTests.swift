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
@Test @MainActor
func settingsFacadeFailureKeepsConfirmedLabelAndReconcilesOnExplicitRestore() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let fixture = SettingsFacadeFixture()
    let workflow = fixture.workflow()
    _ = try await workflow.restore()
    fixture.failSave = true
    await #expect(throws: (any Error).self) {
        try await workflow.save(.init(enabled: true, url: "https://example.invalid", key: "fixture", model: "new"))
    }
    #expect(workflow.modelName == "old")
    #expect(try await workflow.restore().model == "old")
    #expect(fixture.restores == 2)
}
@Test @MainActor
func settingsFacadeCommitsOnlyAcknowledgedInjectedSave() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let fixture = SettingsFacadeFixture()
    let workflow = fixture.workflow()
    _ = try await workflow.restore()
    try await workflow.save(.init(enabled: true, url: "https://example.invalid", key: "fixture", model: "new"))
    #expect(workflow.modelName == "new")
    #expect(try await workflow.restore().model == "new")
    #expect(fixture.restores == 1)
}
