import Foundation
import FunctionContracts

/// History.Conversation function ownership; current invocation paths remain compatible.
extension HistoryActions {
    @Action(domain: "History", module: "Conversation", title: "startNew", serializationKey: "History")
    public static func startNew(invocation: any FunctionInput, using history: any HistoryMutationCapability)
        async throws -> String
    {
        try Task.checkCancellation()
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        let archived = try await history.startNew()
        try Task.checkCancellation()
        return "{\"archived\":" + (archived.map { "\"" + $0.uuidString + "\"" } ?? "null") + "}"
    }

    @Action(
        domain: "History", module: "Conversation", title: "summarize", serializationKey: "History",
        timeout: .seconds(60))
    public static func summarize(invocation: any FunctionInput, using history: any HistoryMutationCapability)
        async throws -> String
    {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["id"])
        let rawID = try arguments.requiredString("id", maximumUTF8Bytes: 36)
        guard let id = UUID(uuidString: rawID) else { throw ActionArguments.ValidationError.invalidValue("id") }
        try await history.summarizeArchived(id)
        try Task.checkCancellation()
        return "{\"summarized\":\"" + id.uuidString + "\"}"
    }

    @Action(
        domain: "History", module: "Conversation", title: "delete", serializationKey: "History")
    public static func delete(invocation: any FunctionInput, using history: any HistoryMutationCapability) async throws
        -> String
    {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["id"])
        let rawID = try arguments.requiredString("id", maximumUTF8Bytes: 36)
        guard let id = UUID(uuidString: rawID) else { throw ActionArguments.ValidationError.invalidValue("id") }
        try await history.deleteArchived(id)
        try Task.checkCancellation()
        return "{\"deleted\":\"" + id.uuidString + "\"}"
    }

    @Action(
        domain: "History", module: "Conversation", title: "list", serializationKey: "History")
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
        domain: "History", module: "Conversation", title: "read", serializationKey: "History")
    public static func read(invocation: any FunctionInput, using history: any HistoryQueryCapability) async throws
        -> String
    {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["id", "offset", "limit"])
        let rawID = try arguments.requiredString("id", maximumUTF8Bytes: 36)
        guard let id = UUID(uuidString: rawID) else { throw ActionArguments.ValidationError.invalidValue("id") }
        let offset = try arguments.requiredInt("offset", range: 0...256)
        let limit = try arguments.requiredInt("limit", range: 1...2)
        let result = try await history.read(id: id, offset: offset, limit: limit)
        try Task.checkCancellation()
        guard result.utf8.count <= 1800 else { throw HistoryQueryError.resultTooLarge }
        return result
    }
}
