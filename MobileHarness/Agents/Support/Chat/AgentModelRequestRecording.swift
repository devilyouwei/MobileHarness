import Foundation
import ModelKit
import Synchronization

/// Agent-owned history recording over existing model inputs and outputs, never provider interception.
public final class AgentModelRequestRecording: Sendable {
    public struct Snapshot: Sendable {
        public let requestJSON: String
        public let responseJSON: String
    }
    private struct Event: Codable, Sendable {
        let kind: String
        var text: String?
        var call: ChatToolCall?
        var usage: [String: Int]?
        var reason: String?
    }
    private let requestJSON: String
    private let events = Mutex<[Event]>([])
    public init(_ request: ChatRequest) throws {
        var value: [String: Any] = [
            "messages": try JSONSerialization.jsonObject(with: JSONEncoder().encode(request.messages)),
            "temperature": request.temperature,
            "tools": try request.tools.map { try JSONSerialization.jsonObject(with: $0.declaration) },
            "requestID": request.context.requestID,
        ]
        value["maximumOutputTokens"] = request.maximumOutputTokens
        value["scopeID"] = request.context.scopeID
        requestJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
    }
    public func record(_ event: ChatEvent) {
        let item: Event
        switch event {
        case .text(let text): item = .init(kind: "text", text: text)
        case .toolCall(let call): item = .init(kind: "toolCall", call: call)
        case .usage(let usage):
            var values = ["input": usage.input, "generated": usage.generated, "total": usage.total]
            values["cachedInput"] = usage.cachedInput
            values["cacheWriteInput"] = usage.cacheWriteInput
            item = .init(kind: "usage", usage: values)
        case .finished(let reason):
            let value: String
            switch reason {
            case .stop: value = "stop"
            case .lengthLimit: value = "lengthLimit"
            case .toolCalls: value = "toolCalls"
            }
            item = .init(kind: "finished", reason: value)
        }
        events.withLock { $0.append(item) }
    }
    public func snapshot() throws -> Snapshot {
        let captured = events.withLock { $0 }
        return .init(
            requestJSON: requestJSON, responseJSON: String(decoding: try JSONEncoder().encode(captured), as: UTF8.self))
    }
}
