import Foundation
import ToolRuntime

public enum HistoryTools {
    @Tool(path: "History.delete", title: "delete")
    public static func delete(call: ToolRequest, using history: any HistoryMutationCapability) async throws -> String {
        try Task.checkCancellation()
        let arguments = ToolArguments(call.arguments)
        try arguments.validateAllowedKeys(["id"])
        let rawID = try arguments.requiredString("id", maximumUTF8Bytes: 36)
        guard let id = UUID(uuidString: rawID) else { throw ToolArguments.ValidationError.invalidValue("id") }
        try await history.deleteArchived(id)
        try Task.checkCancellation()
        return "{\"deleted\":\"" + id.uuidString + "\"}"
    }

    @Tool(path: "History.list", title: "list")
    public static func list(call: ToolRequest, using history: any HistoryQueryCapability) async throws
        -> String
    {
        try Task.checkCancellation()
        let arguments = ToolArguments(call.arguments)
        try arguments.validateAllowedKeys(["offset", "limit"])
        let offset = try arguments.requiredInt("offset", range: 0...64)
        let limit = try arguments.requiredInt("limit", range: 1...5)
        let result = try await history.list(offset: offset, limit: limit)
        try Task.checkCancellation()
        guard result.utf8.count <= 1800 else { throw HistoryQueryError.resultTooLarge }
        return result
    }

    @Tool(path: "History.read", title: "read")
    public static func read(call: ToolRequest, using history: any HistoryQueryCapability) async throws
        -> String
    {
        try Task.checkCancellation()
        let arguments = ToolArguments(call.arguments)
        try arguments.validateAllowedKeys(["id", "offset", "limit"])
        let rawID = try arguments.requiredString("id", maximumUTF8Bytes: 36)
        guard let id = UUID(uuidString: rawID) else { throw ToolArguments.ValidationError.invalidValue("id") }
        let offset = try arguments.requiredInt("offset", range: 0...256)
        let limit = try arguments.requiredInt("limit", range: 1...2)
        let result = try await history.read(id: id, offset: offset, limit: limit)
        try Task.checkCancellation()
        guard result.utf8.count <= 1800 else { throw HistoryQueryError.resultTooLarge }
        return result
    }
}
