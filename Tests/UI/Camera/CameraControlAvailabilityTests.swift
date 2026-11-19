import Testing

@testable import UI

@Test @MainActor func readyCameraCanSwitchWhileUnrelatedModelsAreNotReady() async throws {
    let root = UIContainer()
    try root.start()
    let camera = root.camera.state
    camera.isEnabled = true
    camera.isVisible = true
    for preparation in [
        HomeModelPreparation.checking, .preparing("language"), .preparing("vision"), .deferred,
        .failed(component: "synthesis", message: "fixture"), .ready,
    ] {
        root.home.presentModelPreparation(preparation)
        #expect(camera.canSwitchCamera)
    }
    try root.setForeground(false)
    #expect(!camera.canSwitchCamera)
    try root.setForeground(true)
    #expect(!camera.canSwitchCamera)
    camera.isVisible = true
    #expect(camera.canSwitchCamera)
    await root.stop()
    #expect(!camera.canSwitchCamera)
}

@Test(arguments: ["disabled", "notRunning", "cameraBusy", "controlBusy", "photoBusy", "permission"])
@MainActor func cameraSwitchWaitsForItsOwnReadinessAndConflictingOperations(_ condition: String) async throws {
    let root = UIContainer()
    try root.start()
    let camera = root.camera.state
    camera.isEnabled = true
    camera.isVisible = true
    switch condition {
    case "disabled": camera.isEnabled = false
    case "notRunning": camera.isVisible = false
    case "cameraBusy": camera.isBusy = true
    case "controlBusy": camera.controlBusy = true
    case "photoBusy": camera.photoBusy = true
    case "permission": camera.needsSettings = true
    default: Issue.record("Unknown condition")
    }
    #expect(!camera.canSwitchCamera)
    await root.stop()
}
