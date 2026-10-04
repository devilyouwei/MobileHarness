import ActionRuntime
import Actions
import AgentCore
import Foundation
import Testing
import ToolRuntime
import Tools
import Types

@testable import Agents

private func faceObservation(
    _ centers: [Double], time: Double, confidence: Float = 0.9, rotation: Int = 0
) throws -> PoseObservation {
    let people = centers.map { center in
        (0..<17).map { index in
            PoseObservation.Joint(
                x: Float(center * 100 + Double(index % 3 - 1) * 3), y: 40,
                confidence: index < 5 ? confidence : 0)
        }
    }
    return try PoseObservation(
        width: 100, height: 100, sequence: UInt64(time * 1000 + 1),
        timestamp: time, rotation: rotation, people: people)
}

@Test func gazeMirrorsOnceAndIgnoresLowConfidenceFaces() throws {
    var front = FaceGazeTracker(mirrored: true)
    var back = FaceGazeTracker(mirrored: false)
    let observation = try faceObservation([0.8], time: 0)
    let a = front.update(observation)
    let b = back.update(observation)
    #expect(a.x < 0 && b.x > 0 && abs(a.x + b.x) < 0.00001)
    #expect(a.y < 0 && b.y < 0)
    var uncertain = FaceGazeTracker(mirrored: false)
    #expect(uncertain.update(try faceObservation([0.8], time: 0, confidence: 0.2)) == .init())
}

@Test func gazeHoldsTargetAcrossReorderingAndBriefLossThenReturnsToCenter() throws {
    var tracker = FaceGazeTracker(mirrored: false)
    _ = tracker.update(try faceObservation([0.75], time: 0))
    let locked = tracker.update(try faceObservation([0.2, 0.76], time: 0.1))
    #expect(locked.x > 0)
    let held = tracker.update(try faceObservation([0.2], time: 0.2))
    #expect(held == locked)
    let returning = tracker.update(try faceObservation([], time: 0.5))
    #expect(returning.x < held.x && returning.x > 0)
    for i in 6...30 { _ = tracker.update(try faceObservation([], time: Double(i) / 10)) }
    #expect(tracker.update(try faceObservation([], time: 3.1)) == .init())
    let reacquired = tracker.update(try faceObservation([0.2], time: 3.2))
    #expect(reacquired.x < 0)
}

@Test func gazeSuppressesJitterAndReacquiresAfterOrientationChange() throws {
    var tracker = FaceGazeTracker(mirrored: false)
    for i in 0...20 { _ = tracker.update(try faceObservation([0.7], time: Double(i) / 10)) }
    let still = tracker.update(try faceObservation([0.7], time: 2.1))
    #expect(tracker.update(try faceObservation([0.701], time: 2.2)) == still)
    let turned = tracker.update(try faceObservation([0.15], time: 2.3, rotation: 1))
    #expect(turned.x < still.x)
    #expect((-1...1).contains(turned.x) && (-1...1).contains(turned.y))
}

@Test(arguments: [[:], ["x": "nan", "y": "0"], ["x": "0", "y": "inf"], ["x": "1.1", "y": "0"]])
func moveEyesRejectsInvalidTarget(parameters: [String: String]) async throws {
    let valid = ActionCall(
        actionPath: .init(module: "UI", function: "moveEyes"), channel: "Gaze", parameters: ["x": "0", "y": "0"])
    let call = ActionCall(actionPath: valid.actionPath, channel: valid.channel, parameters: parameters)
    let input = AgentInput(sessionID: UUID(), payload: .text("test"))
    let envelope = OutputEnvelope(source: .visionPerception, input: input, output: .actionCall(call))
    await #expect(throws: UITools.GazeError.invalidTarget) {
        try await UITools.moveEyes(invocation: uiToolInvocation(ActionInvocation(envelope: envelope))) { _, _ in
            Issue.record("Invalid gaze reached presentation")
        }
    }
}

@Test func moveEyesAcceptsBoundaryAndPropagatesPresentationFailure() async throws {
    let call = ActionCall(
        actionPath: .init(module: "UI", function: "moveEyes"), channel: "Gaze", parameters: ["x": "-1", "y": "1"])
    let envelope = OutputEnvelope(
        source: .visionPerception,
        input: AgentInput(sessionID: UUID(), payload: .text("test")), output: .actionCall(call))
    let invocation = try ActionInvocation(envelope: envelope)
    try await UITools.moveEyes(invocation: uiToolInvocation(invocation)) { target, _ in
        #expect(target.x == -1 && target.y == 1)
    }
    await #expect(throws: CancellationError.self) {
        try await UITools.moveEyes(invocation: uiToolInvocation(invocation)) { _, _ in throw CancellationError() }
    }
}
