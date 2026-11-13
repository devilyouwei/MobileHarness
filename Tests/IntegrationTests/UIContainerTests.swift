import AppStorage
import CoreVideo
import Foundation
import Testing

@testable import UI

@MainActor private func uiFullEventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw UIContainerError.unavailable }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor private func uiFullFrame(_ sequence: UInt64) throws -> CameraVideoFrame {
    var pixels: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixels)
    #expect(status == kCVReturnSuccess)
    return CameraVideoFrame(
        pixels: try #require(pixels), width: 2, height: 2, rotation: 0, sequence: sequence, capturedAt: .now)
}

extension LiveRuntimeTests {
    @Test @MainActor func uiFullRegistryCachesEightCapabilitiesAndIsolatesRoots() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = UIConfiguration(
            settings: .init(enabled: true, url: "https://fixture.invalid", key: "fixture", model: "fixture"))
        let registry = ApplicationContainer(root: path, uiConfiguration: configuration)
        let other = ApplicationContainer(root: path, uiConfiguration: configuration)
        let root = registry.ui()
        #expect(root === registry.ui())
        #expect(root.home === registry.homePresentation())
        #expect(root.camera === registry.cameraPresentation())
        #expect(root.settings === registry.settingsPresentation())
        #expect(root.modelResources === registry.modelResourcesPresentation())
        #expect(root.navigation === registry.navigationPresentation())
        #expect(root.history === registry.historyPresentation())
        #expect(root.devices === registry.devicesPresentation())
        #expect(root.diagnostics === registry.diagnosticsPresentation())
        #expect(root.home.conversation !== other.ui().home.conversation)
        #expect(root.runtimeLog !== other.ui().runtimeLog)
        #expect(root.settings.state !== other.ui().settings.state)
        #expect(root.diagnostics.speech !== other.ui().diagnostics.speech)
        #expect(root.settings.state.url == "https://fixture.invalid")
        #expect(!root.isAvailable)
        #expect(!root.settings.presentation.present(.notice("early")))
        #expect(!root.home.conversationPresentation.present(.liveTranscript("early")))
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(root.runtimeLog.items.isEmpty && root.camera.state.videoFrame == nil)
        await root.stop()
        await other.ui().stop()
    }
}

extension LiveRuntimeTests {
    @Test @MainActor func uiFullInjectedPortsUpdateTheSameViewModels() async throws {
        let root = UIContainer()
        try root.start()
        let conversation: any ConversationPresenting = root.home.conversationPresentation
        #expect(conversation.present(.voiceStatus("ready")))
        #expect(conversation.present(.liveTranscript("hello")))
        #expect(root.settings.presentation.present(.notice("ready")))
        #expect(root.modelResources.presentation.present(.hasRestored(true)))
        root.navigation.presentation.show(.assistantHistory)
        #expect(root.devices.presentation.present(.availability(.available)))
        root.diagnostics.speechPresentation.presentReport("actual report")
        #expect(root.home.conversation.liveTranscript == "hello")
        #expect(root.home.conversation.voiceStatus == "ready")
        #expect(root.settings.state.notice == "ready")
        #expect(root.modelResources.state.hasRestored)
        #expect(root.navigation.state.path == [.settings, .assistantHistory])
        #expect(root.devices.state.availability == .available)
        #expect(root.diagnostics.speech.report == "actual report")
        await root.stop()
    }
}

extension LiveRuntimeTests {
    @Test @MainActor func uiFullBackgroundRetainsFactsAndRejectsLiveAndOldEpochs() async throws {
        let root = UIContainer()
        try root.start()
        root.navigation.presentation.show(.settings)
        #expect(root.settings.presentation.present(.url("https://draft.invalid")))
        let token = root.home.token
        let cameraToken = root.camera.token
        try root.camera.presentVideo(uiFullFrame(1), token: cameraToken)
        #expect(root.home.present(.liveTranscript("first"), token: token))
        root.invalidate()
        #expect(root.camera.state.videoFrame == nil)
        #expect(!root.home.conversationPresentation.present(.liveTranscript("late")))
        #expect(root.settings.presentation.present(.notice("background fact")))
        #expect(root.devices.presentation.present(.error("background device fact")))
        let issue = ExecutionIssue(
            title: "failure", source: "runtime", message: "background", userMessage: "background")
        root.runtimeLog.record(.issue(issue))
        root.home.notices.offerToast(issue)
        #expect(root.runtimeLog.issues.count == 1)
        #expect(root.home.notices.errorToast == nil)
        try root.setForeground(true)
        #expect(!root.home.present(.liveTranscript("old generation"), token: token))
        #expect(throws: UIContainerError.unavailable) {
            try root.camera.presentVideo(uiFullFrame(2), token: cameraToken)
        }
        #expect(root.home.present(.liveTranscript("new generation"), token: root.home.token))
        #expect(root.settings.state.url == "https://draft.invalid")
        #expect(root.navigation.state.path == [.settings])
        #expect(root.home.notices.errorToast == nil)
        #expect(!root.home.conversation.isVoiceActive)
        await root.stop()
    }
}

extension LiveRuntimeTests {
    @Test @MainActor func uiFullStopClosesEveryPresentationAndClearsSecretsWithoutAffectingReplacement() async throws {
        let root = UIContainer(
            configuration: .init(
                settings: .init(enabled: true, url: "https://fixture.invalid", key: "secret", model: "fixture")))
        try root.start()
        let settings = root.settings.presentation
        let history = root.history.presentation
        let device = root.devices.presentation
        let diagnostic = root.diagnostics.speechPresentation
        let oldToken = root.home.token
        async let first: Void = root.stop()
        async let second: Void = root.stop()
        _ = await (first, second)
        #expect(root.settings.state.key.isEmpty)
        #expect(!settings.present(.key("late secret")))
        #expect(!history.present(.status("late history")))
        #expect(!device.present(.error("late device")))
        diagnostic.presentReport("late report")
        #expect(root.diagnostics.speech.report != "late report")
        #expect(!root.home.present(.assistantReply("late reply"), token: oldToken))
        #expect(throws: UIFailure.self) { try root.start() }
        let replacement = UIContainer()
        try replacement.start()
        #expect(!replacement.home.present(.assistantReply("foreign epoch"), token: oldToken))
        #expect(replacement.home.conversation.assistantReply.isEmpty)
        await replacement.stop()
    }
}

extension LiveRuntimeTests {
    @Test @MainActor func uiFullHomeOwnsToastExpiryWithoutAViewAndStopJoinsEffects() async throws {
        let root = UIContainer()
        root.home.notices.toastDuration = .milliseconds(20)
        try root.start()
        let issue = ExecutionIssue(
            id: "fault", title: "fault", source: "runtime", message: "detail", userMessage: "notice")
        root.runtimeLog.record(.issue(issue))
        root.home.notices.offerToast(issue)
        #expect(root.home.notices.errorToast?.id == "fault")
        try await uiFullEventually { root.home.notices.errorToast == nil }
        #expect(root.runtimeLog.issues.count == 1)
        try await root.home.effects.showNotice(
            .init(text: "temporary", tone: .warning), durationMS: 30_000,
            owner: .init(source: "fixture", session: "fixture"))
        await root.stop()
        #expect(root.home.notices.notice == nil)
        #expect(root.home.notices.errorToast == nil)
    }
}

extension LiveRuntimeTests {
    @Test @MainActor func uiFullInvalidationReleasesRealExpressionWaiter() async throws {
        let root = UIContainer()
        try root.start()
        #expect(root.home.conversationPresentation.present(.isVoiceActive(true)))
        root.home.conversation.expressionRendererAvailable = true
        let rendering = Task { try await root.home.expressions.perform(.happy, owner: "fixture") }
        try await uiFullEventually { root.home.conversation.expressionTransitionID != nil }
        root.invalidate()
        await #expect(throws: CancellationError.self) { try await rendering.value }
        #expect(root.home.conversation.expressionTransitionID == nil)
        #expect(!root.home.conversation.expressionEmphasized)
        await root.stop()
    }
}

extension LiveRuntimeTests {
    @Test @MainActor func uiFullPreservesResourceGenerationSettingsRevisionAndHistoryTickets() async throws {
        let root = UIContainer()
        try root.start()
        let settings = root.settings.presentation
        let revision = settings.revision
        #expect(settings.present(.url("edited")))
        #expect(!settings.presentFailure("old failure", revision: revision))
        let resources = root.modelResources.presentation
        let first = resources.beginRefresh()
        _ = resources.beginRefresh()
        #expect(!resources.applyRefreshFailure("old failure", generation: first))
        let history = root.history.presentation
        let ticket = try #require(history.beginArchivePage(after: "cursor", retry: false))
        history.cancelArchivePage(ticket)
        let next = try #require(history.beginArchivePage(after: "cursor", retry: false))
        history.finishArchivePage(ticket, error: "old failure")
        #expect(history.archivePaging.accepts(next))
        #expect(history.archivePaging.error == nil)
        await root.stop()
    }
}

extension LiveRuntimeTests {
    @Test @MainActor func uiFullStagesOnlyLatestDeviceFactsBeforeStartWithoutOpeningDevices() async throws {
        let root = UIContainer()
        var value = BluetoothViewSnapshot()
        value.availability = .poweredOff
        root.devices.presentation.apply(value)
        value.availability = .available
        root.devices.presentation.apply(value)
        #expect(root.devices.state.availability == .unknown)
        try root.start()
        #expect(root.devices.state.availability == .available)
        await root.stop()
        value.availability = .poweredOff
        root.devices.presentation.apply(value)
        #expect(root.devices.state.availability == .available)
    }
}
