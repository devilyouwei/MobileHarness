import Testing

@testable import UI

@Test @MainActor func providerFormEditsAdvanceRevisionWithoutExecutingOperations() {
    let state = SettingsState(initial: .init(enabled: false, url: "", key: "", model: "default"))
    let revision = state.revision
    state.url = "https://example.test"
    state.key = "editable-fixture"
    #expect(state.revision == revision + 2)
    #expect(!state.isLoading && !state.isSaving)
    #expect(state.models.isEmpty)
}
