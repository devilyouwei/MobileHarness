import Foundation
import FunctionContracts
import StorageCore

/// History.Conversation function ownership.
extension HistoryActions {
    @Action(domain: "History", module: "Conversation", title: "startNew")
    public static func startNew(invocation: any FunctionInput, using history: any HistoryMutationCapability)
        async throws -> String
    {
        try Task.checkCancellation()
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        let archived = try await history.startNew()
        try Task.checkCancellation()
        return "{\"archived\":" + (archived.map { "\"" + $0 + "\"" } ?? "null") + "}"
    }

    @Action(
        domain: "History", module: "Conversation", title: "summarize",
        timeout: .seconds(60))
    public static func summarize(invocation: any FunctionInput, using history: any HistoryMutationCapability)
        async throws -> String
    {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["id"])
        let rawID = try arguments.requiredString("id", maximumUTF8Bytes: 36)
        guard let id = BusinessRecordID(rawValue: rawID), id.kind == .dialog else {
            throw ActionArguments.ValidationError.invalidValue("id")
        }
        try await history.summarizeArchived(id.rawValue)
        try Task.checkCancellation()
        return "{\"summarized\":\"" + id.rawValue + "\"}"
    }

    @Action(
        domain: "History", module: "Conversation", title: "delete")
    public static func delete(invocation: any FunctionInput, using history: any HistoryMutationCapability) async throws
        -> String
    {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["id"])
        let rawID = try arguments.requiredString("id", maximumUTF8Bytes: 36)
        guard let id = BusinessRecordID(rawValue: rawID), id.kind == .dialog else {
            throw ActionArguments.ValidationError.invalidValue("id")
        }
        try await history.deleteArchived(id.rawValue)
        try Task.checkCancellation()
        return "{\"deleted\":\"" + id.rawValue + "\"}"
    }

    @Action(
        domain: "History", module: "Conversation", title: "list",
        doc:
            "List current and archived conversations, current first then newest archives. Returns paged JSON metadata with canonical dialog_number IDs and and truncated title/input previews. Copy the exact returned id for History.read. Start at offset 0; use nextOffset for more.",
        parameters: [
            .init(
                "offset", type: .string, required: true,
                description: "Decimal integer from 0 through 64, encoded as a string.", constraints: ""),
            .init(
                "limit", type: .string, required: true,
                description: "Decimal integer from 1 through 5, encoded as a string.", constraints: ""),
        ])
    public static func list(invocation: any FunctionInput, using history: any HistoryQueryCapability) async throws
        -> String
    {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["offset", "limit"])
        let offset = try arguments.requiredInt("offset", range: 0...64)
        let limit = try arguments.requiredInt("limit", range: 1...5)
        let result = try await history.list(offset: offset, limit: limit)
        try Task.checkCancellation()
        guard result.utf8.count <= 1800 else { throw HistoryQueryError.resultTooLarge }
        return result
    }

    @Action(
        domain: "History", module: "Conversation", title: "read",
        doc:
            "Read a conversation using the exact conversation_number id returned by History.list. Never invent or repair an identifier. Request blocks and compressed Tasks are oldest first. Returns paged JSON with bounded user/response previews and truncation flags; never replays behavior. Start at offset 0.",
        parameters: [
            .init(
                "id", type: .string, required: true,
                description:
                    "Exact conversation_number id returned by History.list.",
                constraints: ""
            ),
            .init(
                "offset", type: .string, required: true,
                description: "Decimal integer from 0 through 1000000, encoded as a string.", constraints: ""),
            .init(
                "limit", type: .string, required: true,
                description: "Decimal integer from 1 through 2, encoded as a string.", constraints: ""),
        ])
    public static func read(invocation: any FunctionInput, using history: any HistoryQueryCapability) async throws
        -> String
    {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["id", "offset", "limit"])
        let rawID = try arguments.requiredString("id", maximumUTF8Bytes: 36)
        let reference = try HistoryConversationReference(rawID)
        let offset = try arguments.requiredInt("offset", range: 0...1_000_000)
        let limit = try arguments.requiredInt("limit", range: 1...2)
        let result = try await history.read(reference: reference, offset: offset, limit: limit)
        try Task.checkCancellation()
        guard result.utf8.count <= 1800 else { throw HistoryQueryError.resultTooLarge }
        return result
    }
}
