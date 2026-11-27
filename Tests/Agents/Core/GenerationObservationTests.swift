import AgentCore
import CallRuntime
import Foundation
import FunctionContracts
import Gateway
import Testing

@testable import Agents

@Test(arguments: [#"{"mediaID":"media_23","metadata":null}"#, "[]", "", "opaque-id", "null"])
func compactActionObservationPreservesBusinessContainersScalarsAndEmptyValues(business: String) throws {
    let internalID = UUID().uuidString
    let result = ToolResult(callID: internalID, value: business, completion: .value(business))
    let value = AgentChatContextBuilder.actionObservation(index: 3, name: "takePhoto", result: result)
    #expect(value["call"] as? Int == 3 && value["action"] as? String == "takePhoto")
    #expect(value["status"] as? String == "succeeded")
    #expect(value["callID"] == nil && value["result"] == nil && value["error"] == nil)
    if business.hasPrefix("{") {
        let photo = try #require(value["value"] as? [String: Any])
        #expect(photo["mediaID"] as? String == "media_23" && photo["metadata"] is NSNull)
    } else if business == "[]" {
        #expect((value["value"] as? [Any])?.isEmpty == true)
    } else {
        #expect(value["value"] as? String == business)
    }
    let body = try JSONSerialization.data(withJSONObject: value)
    #expect(!String(decoding: body, as: UTF8.self).contains(internalID))
    #expect(try AgentChatContextBuilder.nativeObservation(result) == business)
}

@Test(arguments: [GenerationError.unknownCapability, .invalidParameters])
func compactRejectionPreservesReasonAndUnexecutedEvidence(reason: GenerationError) throws {
    let id = UUID().uuidString
    let rejection = CallRejection(kind: .action, alias: "closeCamera", callID: id, reason: reason)
    let result = ToolResult(
        callID: id, value: "Rejected before execution", isError: true, failureCode: "invalidInvocation")
    let value = AgentChatContextBuilder.actionObservation(
        index: 1, name: "closeCamera", result: result, rejection: rejection)
    #expect(value["status"] as? String == "rejected" && value["executed"] as? Bool == false)
    let failure = try #require(value["error"] as? [String: Any])
    #expect(failure["code"] as? String == String(describing: reason))
    #expect(failure["message"] as? String == "Rejected before execution")
    #expect(value["effect"] == nil && value["callID"] == nil)
    let native = try AgentChatContextBuilder.nativeObservation(result, rejection: rejection)
    #expect(!native.contains(id) && native.contains("rejected"))
}

@Test(arguments: [ActionResult.Effect.unknown, .notStarted, .contractCompleted])
func compactPartialFailureRetainsActualEffectAndAllLeafOutcomes(effect: ActionResult.Effect) throws {
    let report = try AgentActionReport(entries: [
        .init(path: "first", status: .succeeded, details: ["mediaID": "media_23"]),
        .init(path: "second", status: .failed, code: .handlerFailed, details: ["failureDescription": "actual failure"]),
        .init(path: "third", status: .notStarted),
    ])
    let owner = ExecutionOwner(agent: .assistant, incarnation: UUID().uuidString, sessionID: UUID().uuidString)
    let action = ActionResult(
        executionID: UUID().uuidString, owner: owner,
        path: .init(domain: "Camera", module: "Capture", function: "takePhoto"),
        causality: .root(), status: .partialFailure, effect: effect, completion: .report(report),
        failure: .handlerFailed)
    let result = ToolResult(callID: UUID().uuidString, value: "", isError: true, completion: .report(report))
    let value = AgentChatContextBuilder.actionObservation(index: 2, name: "takePhoto", result: result, action: action)
    #expect(value["status"] as? String == "partialFailure" && value["effect"] as? String == effect.rawValue)
    let details = try #require(value["report"] as? [String: Any])
    let leaves = try #require(details["entries"] as? [[String: Any]])
    #expect(leaves.count == 3)
    #expect((leaves[0]["details"] as? [String: String])?["mediaID"] == "media_23")
    #expect(leaves[1]["code"] as? String == "handlerFailed")
    #expect(leaves[2]["status"] as? String == "notStarted" && leaves[2]["details"] == nil)
    #expect(details["executionFailure"] == nil && details["status"] == nil)
    #expect(
        !String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self).contains(
            try #require(action.executionID))
    )
}

@Test(arguments: [false, true]) func compactReportKeepsIndependentFailureAlongsideCancellation(mixed: Bool) throws {
    var entries: [AgentActionReport.Entry] = [.init(path: "cancelled", status: .cancelled, code: .cancelled)]
    if mixed { entries.append(.init(path: "failed", status: .failed, code: .handlerFailed)) }
    let report = try AgentActionReport(entries: entries)
    let result = ToolResult(callID: UUID().uuidString, value: "", isError: true, completion: .report(report))
    let value = AgentChatContextBuilder.actionObservation(index: 1, name: "operation", result: result)
    #expect(value["status"] as? String == (mixed ? "failed" : "cancelled"))
    #expect(result.requiresReasoning == mixed)
    let body = try JSONSerialization.data(withJSONObject: value)
    let text = String(decoding: body, as: UTF8.self)
    #expect(text.contains("cancelled") && text.contains("handlerFailed") == mixed)
    #expect(!text.contains(":null") && !text.contains("\"details\":{}"))
}

@Test func rejectedActionsKeepCallIdentityWithoutAnExecutionInstance() {
    let owner = ExecutionOwner(agent: .assistant, incarnation: "incarnation", sessionID: "session")
    let path = ActionPath(domain: "Camera", module: "Capture", function: "takePhoto")
    let causality = SignalCausality.root(id: "input")
    let rejected = ActionResult(
        executionID: nil, owner: owner, path: path, causality: causality, status: .failed, effect: .notStarted,
        failure: .handlerFailed, callID: "first", roundID: "round")
    let another = ActionResult(
        executionID: nil, owner: owner, path: path, causality: causality, status: .failed, effect: .notStarted,
        failure: .handlerFailed, callID: "second", roundID: "round")
    let unconfirmed = ActionResult(
        executionID: nil, owner: owner, path: path, causality: causality, status: .failed, effect: .unknown,
        failure: .handlerFailed, callID: "first", roundID: "round")
    var inbox = ActionResultInbox()
    let admitted = inbox.accept(rejected)
    let duplicate = inbox.accept(rejected)
    let admittedAnother = inbox.accept(another)
    #expect(admitted && !duplicate && admittedAnother)

    let error = ToolResult(callID: "first", value: "failed", isError: true)
    let observation = AgentChatContextBuilder.compactResult(error, action: rejected)
    #expect(observation["status"] as? String == "rejected")
    #expect(observation["executed"] as? Bool == false)
    let uncertainObservation = AgentChatContextBuilder.compactResult(error, action: unconfirmed)
    #expect(uncertainObservation["status"] as? String == "failed")
    #expect(uncertainObservation["effect"] as? String == "unknown")
}
