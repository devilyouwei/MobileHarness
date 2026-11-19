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
func navigationKeepsGlobalIslandLiveAndInteractive(_ expanded: Bool) async throws {
    let root = UIContainer()
    try root.start()
    let navigation = root.navigation.state
    let island = root.island
    var content = IslandContent(
        title: "目标", primary: .symbol(name: "scope"), detail: .init(text: "保留详情"))
    let id = try #require(try island.publishSlot(owner: "goal", content: content))
    try island.setExpanded(expanded)
    island.localMounted()
    let frame = CGRect(x: 16, y: 14, width: 370, height: 100)
    island.reserveLocalFrame(frame)
    let generation = island.generation
    let revision = island.localRevision
    island.localCompleted(generation: generation, revision: revision)

    navigation.show(.settings)
    #expect(!root.windows.isHostVisible && island.expanded == expanded)
    #expect(island.localFrame == frame && island.replacesSystemStatusBar && island.statusBar.active)
    #expect(island.available && island.generation == generation)
    #expect(island.localRevision == revision && island.localStatus == "settled")

    // A user's choice on Settings remains authoritative across deeper pages and ordinary content updates.
    try island.setExpanded(!expanded)
    navigation.present(.path([.settings, .assistantHistory]))
    content.detail = .init(text: "最新详情")
    try island.publishSlot(owner: "goal", content: content)
    #expect(island.expanded == !expanded && island.detailActivity?.id == id)
    #expect(island.detailActivity?.content.detail?.text == "最新详情")
    let listening = IslandContent(title: "正在聆听", primary: .spectrum)
    let statusID = try #require(try island.publishSlot(owner: "audio", content: listening))
    try island.spectrum(Array(repeating: 0.25, count: 32), active: true, generation: generation)
    navigation.show(.album)
    #expect(island.compact?.id == statusID && island.statusActivity?.content.title == "正在聆听")
    let playback = IslandContent(title: "正在播放", primary: .symbol(name: "speaker.wave.2"))
    try island.publishSlot(owner: "audio", content: playback)
    #expect(island.statusActivity?.content == playback && island.expanded == !expanded)
    #expect(island.spectrumActive && island.bands == Array(repeating: 0.25, count: 32))

    let beforeBackground = island.localRevision
    try root.setSceneActive(false)
    #expect(island.localFrame == nil && !island.replacesSystemStatusBar && !island.statusBar.active)
    island.localMounted()
    island.localCompleted(generation: generation, revision: beforeBackground)
    #expect(island.localStatus == "detached" && !island.replacesSystemStatusBar)
    try root.setSceneActive(true)
    #expect(island.expanded == !expanded && !root.windows.isHostVisible)
    #expect(island.statusActivity?.content == playback && island.generation == generation)
    island.localMounted()
    #expect(island.replacesSystemStatusBar && island.statusBar.active)
    navigation.path = [.settings]
    navigation.path = []
    #expect(root.windows.isHostVisible && island.expanded == !expanded)
    #expect(island.replacesSystemStatusBar && island.detailActivity?.id == id)
    await root.stop()
    #expect(island.activities.isEmpty && !island.statusBar.active && !island.replacesSystemStatusBar)
}

@Test @MainActor func globalIslandRemovesEndedActivitiesAndRejectsOldRootPreferencesOnAnyPage() async throws {
    let root = UIContainer()
    try root.start()
    let content = IslandContent(title: "目标", primary: .symbol(name: "scope"), detail: .init(text: "详情"))
    let original = try #require(try root.island.publishSlot(owner: "goal", content: content))
    try root.island.setExpanded(false)
    root.navigation.state.show(.assistantHistory)
    try root.island.publishSlot(owner: "goal", content: nil)
    #expect(root.island.compact == nil)
    let replacement = try #require(try root.island.publishSlot(owner: "replacement", content: content))
    #expect(root.island.expanded && root.island.detailActivity?.id == replacement)
    try root.island.setExpanded(false)
    root.navigation.state.show(nil)
    #expect(!root.island.expanded && !root.island.activities.contains { $0.id == original })

    root.navigation.state.show(.album)
    let previousGeneration = root.island.generation
    try root.setForeground(false)
    try root.setForeground(true)
    #expect(root.island.activities.isEmpty && root.island.generation != previousGeneration)
    try root.island.publishSlot(owner: "replacement", content: content)
    #expect(root.island.expanded && !root.windows.isHostVisible)
    root.island.localMounted()
    #expect(root.island.replacesSystemStatusBar)
    root.navigation.state.show(nil)
    #expect(root.island.expanded)
    await root.stop()
}
