import Foundation
import Testing

@testable import UI

@Test @MainActor func navigationContextTracksPathsAndRejectsLateConfirmations() {
    let state = NavigationState()
    let first = state.generation
    #expect(state.confirm(.init(.home), generation: first))
    state.show(.album)
    let album = state.generation
    #expect(state.path == [.settings, .album])
    #expect(state.contextSnapshot().phase == .transitioning)
    #expect(!state.confirm(.init(.home), generation: first))
    #expect(state.confirm(.init(.album), generation: album))
    #expect(state.confirm(.init(.albumPhoto, itemID: "photo"), content: .loading, generation: album))
    state.updateContext(.init(.album), content: .empty, overlay: nil, generation: album)
    #expect(state.contextSnapshot().current?.page == .albumPhoto)
    #expect(
        state.confirm(
            .init(.albumPhoto, itemID: "photo"), content: .ready,
            overlay: .deleteConfirmation, generation: album))
    #expect(state.contextSnapshot().overlay == .deleteConfirmation)
    state.path = [.settings]
    #expect(!state.confirm(.init(.albumPhoto, itemID: "photo"), generation: album))
    #expect(state.contextSnapshot().overlay == nil)
    #expect(state.confirm(.init(.settings), generation: state.generation))
    state.path = []
    #expect(state.confirm(.init(.home), generation: state.generation))
    #expect(state.contextSnapshot().current?.page == .home)
}

@Test @MainActor func navigationContextUsesAlbumFactsOnlyOnAlbumPages() async throws {
    let root = UIContainer()
    try root.start()
    root.navigation.state.show(.album)
    let navigation = root.navigation.state
    #expect(navigation.confirm(.init(.album), generation: navigation.generation))
    #expect(navigation.contextSnapshot(album: root.album.contextSnapshot()).content == .idle)
    root.album.export("photo")
    #expect(navigation.contextSnapshot(album: root.album.contextSnapshot()).operation == .exporting)
    navigation.show(.settings)
    #expect(navigation.contextSnapshot(album: root.album.contextSnapshot()).operation == nil)
    #expect(navigation.confirm(.init(.settings), generation: navigation.generation))
    await root.stop()
    #expect(!navigation.confirm(.init(.settings), generation: navigation.generation))
}
