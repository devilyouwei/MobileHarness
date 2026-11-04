import Testing

@testable import UI

@Test @MainActor func providerFormEditsAdvanceRevisionWithoutExecutingOperations() {
    let state = SettingsState(initial: .init(enabled: false, url: "", key: "", model: "default"))
    let revision = state.revision
    state.url = "https://example.test"
    state.key = "editable-fixture"
    #expect(state.revision == revision + 2)
    #expect(!state.isLoading && !state.isSaving)
    #expect(state.modelCatalogs.isEmpty)
}

@Test @MainActor func providerRestorePreservesMultipleProvidersAndRejectsLateResults() {
    let state = SettingsState(initial: .init(enabled: false, url: "", key: "", model: ""))
    let first = CloudSettingsDraft(enabled: false, url: "https://first.invalid", key: "first-fixture", model: "first")
    let second = CloudSettingsDraft(
        enabled: false, url: "https://second.invalid", key: "second-fixture", model: "second")
    let value = CloudSettingsDraft(
        enabled: true, url: second.url, key: second.key, model: second.model, providers: [first, second])
    #expect(state.presentRestored(value, revision: state.revision))
    #expect(state.providers == [first, second])
    #expect(state.url == second.url && state.key == second.key)
    let old = state.revision
    state.url = first.url
    #expect(!state.presentRestored(value, revision: old))
    #expect(state.url == first.url)
}

@Test func providerModalGeneratesDefaultNamesAndValidatesIndependentDraft() throws {
    let first = CloudSettingsDraft(
        enabled: false, url: "https://first.invalid", key: "existing-fixture", model: "model", name: "Provider 1")
    var editor = ProviderEditorDraft(provider: nil, existing: [first])
    #expect(editor.name == "Provider 2")
    editor.url = "https://second.invalid/v1"
    editor.key = "new-fixture"
    let result = try editor.validated(existing: [first])
    #expect(result.name == "Provider 2" && result.key == "new-fixture")
    #expect(first.key == "existing-fixture")
    editor.url = first.url
    #expect(throws: ProviderEditorError.self) { try editor.validated(existing: [first]) }
    var editing = ProviderEditorDraft(provider: first, existing: [first])
    editing.name = "自定义名称"
    #expect(try editing.validated(existing: [first]).key == first.key)
    editing.name = "   "
    #expect(throws: ProviderEditorError.self) { try editing.validated(existing: [first]) }
}

@Test func providerModalAcceptsHTTPAndHTTPSIPAddresses() throws {
    for url in ["http://192.168.1.20:11434/v1", "https://192.168.1.20:8443/v1", "http://[::1]:8080/v1"] {
        var draft = ProviderEditorDraft(provider: nil, existing: [])
        draft.url = url
        #expect(try draft.validated(existing: []).url == url)
    }
    var draft = ProviderEditorDraft(provider: nil, existing: [])
    draft.url = "ftp://192.168.1.20/v1"
    #expect(throws: ProviderEditorError.self) { try draft.validated(existing: []) }
}

@Test func blankProviderURLResolvesToOpenAIDefaultAndPreventsDuplicates() throws {
    for url in ["", "  ", "\n\t"] {
        var editor = ProviderEditorDraft(provider: nil, existing: [])
        editor.url = url
        editor.key = "fixture-key"
        let value = try editor.validated(existing: [])
        #expect(value.url == "https://api.openai.com/v1")
        #expect(value.key == "fixture-key" && value.name == "Provider 1")
        #expect(throws: ProviderEditorError.self) { try editor.validated(existing: [value]) }
        var editing = ProviderEditorDraft(provider: value, existing: [value])
        editing.url = ""
        #expect(try editing.validated(existing: [value]).url == value.url)
    }
}

@Test @MainActor func writerThinkingDraftRestoresIndependentlyOfAssistantSelection() {
    let draft = CloudSettingsDraft(enabled: true, url: "https://assistant.test", key: "fixture", model: "assistant")
    let state = SettingsState(initial: draft)
    #expect(!state.writerThinking)
    state.writerThinking = true
    #expect(state.selectedModel == "assistant")
    let revision = state.revision
    #expect(state.presentRestored(draft, revision: revision))
    #expect(!state.writerThinking && state.selectedModel == "assistant")
}
