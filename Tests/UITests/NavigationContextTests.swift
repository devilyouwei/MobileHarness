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

@Test(arguments: [false, true]) @MainActor
func navigationSuspendsHomeOverlaysAndRestoresIslandPreference(_ expanded: Bool) async throws {
    let root = UIContainer()
    try root.start()
    let navigation = root.navigation.state
    let island = root.island
    var content = IslandContent(
        title: "目标", primary: .symbol(name: "scope"), detail: .init(text: "保留详情"))
    let id = try #require(try island.publishSlot(owner: "goal", content: content))
    try island.setExpanded(expanded)
    island.localMounted()
    island.reserveLocalFrame(CGRect(x: 16, y: 14, width: 370, height: 100))
    let generation = island.generation
    let revision = island.localRevision

    navigation.show(.settings)
    #expect(!root.windows.isHostVisible && !island.localPresentationVisible && !island.expanded)
    #expect(island.detail == nil && island.localFrame == nil && !island.replacesSystemStatusBar)
    #expect(!island.statusBar.active && island.available && island.generation == generation)
    island.localMounted()
    island.localCompleted(generation: generation, revision: revision)
    #expect(!island.replacesSystemStatusBar && island.localStatus == "detached")

    navigation.present(.path([.settings, .assistantHistory]))
    // Even a new phase cannot overwrite the preference captured on leaving home.
    content.expansionID = "next-phase"
    content.detail = .init(text: "最新详情")
    try island.publishSlot(owner: "goal", content: content)
    #expect(!island.expanded && island.detailActivity?.id == id)
    try root.setSceneActive(false)
    try root.setSceneActive(true)
    #expect(!island.localPresentationVisible && !island.expanded && !root.windows.isHostVisible)
    navigation.path = [.settings]
    #expect(!island.localPresentationVisible)
    navigation.path = []
    #expect(root.windows.isHostVisible && island.localPresentationVisible && island.expanded == expanded)
    #expect(island.detailActivity?.content.detail?.text == "最新详情")
    #expect(island.generation == generation)
    island.localMounted()
    #expect(island.replacesSystemStatusBar)
    await root.stop()
}

@Test @MainActor func navigationDoesNotRestoreEndedIslandActivitiesOrOldRootPreferences() async throws {
    let root = UIContainer()
    try root.start()
    let content = IslandContent(title: "目标", primary: .symbol(name: "scope"), detail: .init(text: "详情"))
    let original = try #require(try root.island.publishSlot(owner: "goal", content: content))
    try root.island.setExpanded(false)
    root.navigation.state.show(.assistantHistory)
    try root.island.publishSlot(owner: "goal", content: nil)
    let replacement = try #require(try root.island.publishSlot(owner: "replacement", content: content))
    root.navigation.state.show(nil)
    #expect(root.island.expanded && root.island.detailActivity?.id == replacement)
    #expect(!root.island.activities.contains { $0.id == original })

    try root.island.setExpanded(false)
    root.navigation.state.show(.album)
    try root.setForeground(false)
    try root.setForeground(true)
    try root.island.publishSlot(owner: "replacement", content: content)
    #expect(!root.island.localPresentationVisible)
    root.navigation.state.show(nil)
    #expect(root.island.expanded)
    await root.stop()
}
