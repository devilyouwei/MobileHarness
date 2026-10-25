import Actions
import ExecutionRuntime
import Foundation
import FunctionContracts
import StorageCore
import Testing

@testable import Agents

private actor FeedbackProbe {
    var cues: [UIActions.CueRequest] = []
    var haptics: [UIActions.HapticRequest] = []
    func cue(_ request: UIActions.CueRequest) { cues.append(request) }
    func haptic(_ request: UIActions.HapticRequest) { haptics.append(request) }
}
private func feedbackInput(_ function: String, _ parameters: [String: String] = [:]) -> FunctionInvocation {
    FunctionInvocation(
        call: .init(actionPath: .init(domain: "UI", module: "Feedback", function: function), parameters: parameters),
        context: .init(
            source: "assistant", sessionID: UUID().uuidString, inputID: UUID().uuidString),
        executionID: UUID().uuidString, results: ActionReportStore())
}

@Test func reusableFeedbackActionsForwardDefaultsAndExplicitParameters() async throws {
    let probe = FeedbackProbe()
    try await UIActions.playCue(invocation: feedbackInput("playCue"), using: { request, _ in await probe.cue(request) })
    try await UIActions.vibrate(
        invocation: feedbackInput("vibrate"), using: { request, _ in await probe.haptic(request) })
    try await UIActions.playCue(
        invocation: feedbackInput("playCue", ["cue": "confirm", "volume": "0.4"]),
        using: { request, _ in await probe.cue(request) })
    try await UIActions.vibrate(
        invocation: feedbackInput(
            "vibrate", ["style": "rigid", "intensity": "0.95", "count": "2", "intervalMS": "120"]),
        using: { request, _ in await probe.haptic(request) })
    #expect(await probe.cues == [try .init(), try .init(cue: .confirm, volume: 0.4)])
    #expect(await probe.haptics == [try .init(), try .init(style: .rigid, intensity: 0.95, count: 2, intervalMS: 120)])
}

@Test(arguments: [["cue": "privateSiri"], ["volume": "nan"], ["volume": "1.1"], ["unexpected": "x"]])
func invalidCueArgumentsNeverInvokeNativeEffect(_ arguments: [String: String]) async {
    let probe = FeedbackProbe()
    await #expect(throws: ActionArguments.ValidationError.self) {
        try await UIActions.playCue(
            invocation: feedbackInput("playCue", arguments), using: { request, _ in await probe.cue(request) })
    }
    #expect(await probe.cues.isEmpty)
}

@Test(arguments: [
    ["style": "siri"], ["intensity": "-0.1"], ["intensity": "inf"], ["count": "4"], ["intervalMS": "39"],
    ["unexpected": "x"],
])
func invalidHapticArgumentsNeverInvokeNativeEffect(_ arguments: [String: String]) async {
    let probe = FeedbackProbe()
    await #expect(throws: ActionArguments.ValidationError.self) {
        try await UIActions.vibrate(
            invocation: feedbackInput("vibrate", arguments), using: { request, _ in await probe.haptic(request) })
    }
    #expect(await probe.haptics.isEmpty)
}

@Test(arguments: UIActions.Cue.allCases) func feedbackCuePCMHasFiniteRampedDistinctProfiles(_ cue: UIActions.Cue) throws
{
    let samples = try FeedbackTone.samples(for: .init(cue: cue, volume: 1))
    #expect((16000...48000).contains(samples.count))
    #expect(samples.allSatisfy { $0.isFinite && abs($0) < 0.5 })
    #expect(samples.first == 0 && abs(samples.last ?? 1) < 0.00001)
    #expect(samples.contains { abs($0) > 0.06 })
    #expect(zip(samples, samples.dropFirst()).allSatisfy { abs($0 - $1) < 0.045 })
    let muted = try FeedbackTone.samples(for: .init(cue: cue, volume: 0))
    #expect(muted.count == samples.count && muted.allSatisfy { $0 == 0 })
}

@Test(.actionCatalog) func feedbackFunctionsRemainCanonicalWithoutSkillExposure() throws {
    let feedback = UIModule.declarations.filter { $0.path.module == "Feedback" }
    #expect(Set(feedback.map(\.path.function)) == ["playCue", "vibrate"])
    let skill = try AgentConfigurations.skill("expression-interaction")
    #expect(!skill.useActions.contains { $0.path == "UI.Feedback.playCue" })
    #expect(!skill.useActions.contains { $0.path == "UI.Feedback.vibrate" })
    let cue = try #require(feedback.first { $0.path.function == "playCue" })
    #expect(
        cue.parameters.first { $0.name == "cue" }?.values == [
            "wake", "confirm", "cancel", "error", "soft", "save", "discard",
        ])
}

@Test func listeningActionForwardsConfiguredFeedback() async throws {
    let call = FunctionRequest(
        actionPath: .init(domain: "Speech", module: "Listening", function: "update"),
        parameters: [
            "enabled": "true", "paused": "false", "revision": "2", "cue": "soft", "volume": "0.6",
            "hapticStyle": "rigid", "hapticIntensity": "0.9",
        ])
    let input = FunctionInvocation(
        call: call, context: feedbackInput("playCue").context, executionID: UUID().uuidString,
        results: ActionReportStore())
    try await SpeechActions.update(invocation: input) { enabled, paused, revision, configuration in
        #expect(enabled && !paused && revision == 2)
        #expect(configuration.cue.cue == .soft && configuration.cue.volume == 0.6)
        #expect(configuration.haptic.style == .rigid && configuration.haptic.intensity == 0.9)
    }
}

@Test func missingFeedbackCapabilityReportsFailureWithoutNoOpSuccess() async throws {
    let definition = try #require(UIModule.feedbackDefinitions(feedback: nil).first { $0.path.function == "playCue" })
    await #expect(throws: UIActions.FeedbackError.self) {
        try await FunctionExecutor.perform(feedbackInput("playCue"), definition: definition)
    }
}

@Test(arguments: [
    ["cue": "unknown"], ["volume": "nan"], ["hapticStyle": "unknown"], ["hapticIntensity": "2"], ["unexpected": "x"],
])
func invalidListeningFeedbackDoesNotReachPolicyOrNativeEffects(_ invalid: [String: String]) async throws {
    var arguments = ["enabled": "true", "paused": "false", "revision": "1"]
    arguments.merge(invalid) { _, new in new }
    let input = FunctionInvocation(
        call: .init(
            actionPath: .init(domain: "Speech", module: "Listening", function: "update"), parameters: arguments),
        context: feedbackInput("playCue").context, executionID: UUID().uuidString,
        results: ActionReportStore())
    await #expect(throws: ActionArguments.ValidationError.self) {
        try await SpeechActions.update(invocation: input) { _, _, _, _ in
            Issue.record("Invalid arguments reached listening policy")
        }
    }
}

#if os(iOS)
    import AVFAudio
    import CoreHaptics
    @testable import PlatformKit

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HAPTIC_DEVICE_ACCEPTANCE"] == "1"))
    @MainActor
    func nativeHapticRestoresRecordingAccessOnEveryRequestAndAfterStop() async throws {
        try #require(CHHapticEngine.capabilitiesForHardware().supportsHaptics)
        let session = AVAudioSession.sharedInstance()
        let original = session.allowHapticsAndSystemSoundsDuringRecording
        let feedback = NativeHapticFeedback()
        var primary: (any Error)?
        do {
            for count in [1, 3, 1, 2, 1] {
                // Simulate a recording owner resetting the shared session between activations.
                try session.setAllowHapticsAndSystemSoundsDuringRecording(false)
                try await feedback.impact(style: .rigid, intensity: 0.9, count: count, intervalMS: 40)
                #expect(session.allowHapticsAndSystemSoundsDuringRecording)
                await feedback.stop()
            }
        } catch {
            primary = error
        }
        await feedback.stop()
        do {
            try session.setAllowHapticsAndSystemSoundsDuringRecording(original)
        } catch {
            if let primary { throw AudioIOCleanupError(primary: primary, cleanup: error) }
            throw error
        }
        if let primary { throw primary }
    }
#endif
