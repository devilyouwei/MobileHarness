import Foundation
import ModelKit
import StorageChat
import StorageCore
import Synchronization

/// Agent-owned history recording over existing model inputs and outputs, never provider interception.
public final class AgentModelRequestRecording: Sendable {
    public struct Snapshot: Sendable {
        public var initial = false
        public var transport: ModelRequestLogUpdate? = nil
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
    private let httpCapture = Mutex(false)
    private let captureFailure = Mutex<String?>(nil)
    private let requestJSON: String
    private let events = Mutex<[Event]>([])
    public init(_ request: ChatRequest) throws {
        let messages = try request.messages.map { message -> [String: Any] in
            let textOnly = ChatMessage(
                role: message.role, content: message.content, toolCalls: message.toolCalls,
                toolCallID: message.toolCallID)
            guard var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(textOnly)) as? [String: Any]
            else { throw CocoaError(.coderInvalidValue) }
            if let images = message.images {
                value["images"] = try images.map { image -> [String: Any] in
                    guard
                        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(image))
                            as? [String: Any]
                    else { throw CocoaError(.coderInvalidValue) }
                    return encoded
                }
            }
            return value
        }
        var value: [String: Any] = [
            "messages": messages,
            "temperature": request.temperature,
            "tools": try request.tools.map { try JSONSerialization.jsonObject(with: $0.declaration) },
            "requestID": request.context.requestID,
        ]
        value["maximumOutputTokens"] = request.maximumOutputTokens
        value["scopeID"] = request.context.scopeID
        requestJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
    }
    public func transportRecorder(_ consume: @escaping @Sendable (Snapshot) async throws -> Void)
        -> @Sendable (ChatTransportEvent) async -> Void
    {
        { [self] event in
            let update: ModelRequestLogUpdate
            switch event {
            case .request(let method, let url, let headers, let body, let at):
                httpCapture.withLock { $0 = true }
                events.withLock { $0.removeAll() }
                update = .request(method: method, url: url, headers: headers, body: body, at: at)
            case .response(let status, let headers, let at):
                update = .response(status: status, headers: headers, at: at)
            case .bytes(let bytes, let at): update = .bytes(bytes, at: at)
            case .finished(let at, let error):
                update = .finished(at: at, error: error ?? captureFailure.withLock { $0 })
            }
            do { try await consume(.init(transport: update, requestJSON: "", responseJSON: "")) } catch {
                captureFailure.withLock { $0 = String(describing: error) }
            }
        }
    }
    public func record(_ event: ChatEvent) {
        guard !httpCapture.withLock({ $0 }) else { return }
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
    public func snapshot(initial: Bool = false) throws -> Snapshot {
        let captured = events.withLock { $0 }
        return .init(
            initial: initial,
            requestJSON: requestJSON, responseJSON: String(decoding: try JSONEncoder().encode(captured), as: UTF8.self))
    }
}
