import Foundation
import StorageChat
import Testing
import UI

@Test func historyTitlesUsePresentationFallbacksAndRawInput() async throws {
    let store = ConversationHistoryStore()
    #expect(ConversationHistoryPresentation.title(try await store.snapshot().current) == "新对话")
    let read = try await store.readCurrent()
    let id = UUID()
    _ = try await store.begin(
        id: id, user: "  original input  ", request: [], expecting: read.token, model: "fixture")
    #expect(ConversationHistoryPresentation.title(try await store.snapshot().current) == "  original input  ")
    try await store.finish(id, state: .completed)
    let archive = try #require(try await store.startNew())
    #expect(ConversationHistoryPresentation.title(archive) == "待生成标题")
    try await store.setTitle("Summary", for: archive.id)
    let titled = try #require(try await store.snapshot().past.first)
    #expect(ConversationHistoryPresentation.title(titled) == "Summary")
}
