import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import StorageChat
import StorageCore
import StorageTasks
import UI

extension WriterAgent {
    public func observationSnapshot() async -> AgentStateSnapshot {
        let presentationFailure = await island.lastFailure
        let id = requests.keys.first
        return .init(
            path: "agents.writer",
            business: [
                "lifecyclePhase": .text(lifecycle.rawValue),
                "agentID": .text("writer"),
                "activeWorkspaces": .texts(requests.values.compactMap(\.workspaceID).sorted()),
                "presentationFailure": presentationFailure.map { .text($0) } ?? .unknown,
                "phase": .text(
                    id == nil ? "idle" : lifecycle == .paused ? "paused" : id.flatMap { phases[$0] } ?? "starting"),
                "workspaceID": id.flatMap { requests[$0]?.workspaceID }.map { .text($0) } ?? .unknown,

                "goal": id.flatMap { requests[$0]?.request }.map { .text($0) } ?? .unknown,
                "step": id.flatMap { lastSteps[$0] }.map { .text($0) } ?? .unknown,
                "waitingForInput": .flag(id.flatMap { waiting[$0] } != nil),
            ],
            runtime: [
                "rolePhase": .text(lifecycle.rawValue), "failures": .count(failures.count),
                "lastFailure": failures.values.sorted().last.map { .text($0) } ?? .unknown,
                "pendingReports": .count(pendingReports.values.reduce(0) { $0 + $1.count }),
                "backgroundFailure": backgroundFailure.map { .text($0) } ?? .unknown,
                "deliveryFailure": deliveryFailures.values.sorted().last.map { .text($0) } ?? .unknown,
            ])
    }
}
