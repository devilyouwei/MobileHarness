import Foundation
import ToolRuntime

public protocol HistoryQueryCapability: Sendable {
    func list(offset: Int, limit: Int) async throws -> String
    func read(id: UUID, offset: Int, limit: Int) async throws -> String
}

public struct HistoryToolModule: ToolModule {
    private let history: any HistoryQueryCapability
    public init(history: any HistoryQueryCapability) { self.history = history }
    public var definitions: [ToolDefinition] {
        [
            HistoryTools.listDefinition(handler: { [history] call in
                try await HistoryTools.list(call: call, using: history)
            }),
            HistoryTools.readDefinition(handler: { [history] call in
                try await HistoryTools.read(call: call, using: history)
            }),
        ]
    }
}
