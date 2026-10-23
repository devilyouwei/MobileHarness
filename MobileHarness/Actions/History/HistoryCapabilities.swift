import Foundation
import FunctionContracts
import StorageCore

public struct HistoryConversationReference: Sendable, Equatable {
    public let value: String
    public init(id: String) { value = id }
    public init(_ raw: String) throws {
        guard let id = BusinessRecordID(rawValue: raw), id.kind == .dialog else {
            throw ActionArguments.ValidationError.invalidValue("id")
        }
        value = id.rawValue
    }
}

public protocol HistoryQueryCapability: Sendable {
    func list(offset: Int, limit: Int) async throws -> String
    func read(reference: HistoryConversationReference, offset: Int, limit: Int) async throws -> String
}

public protocol HistoryMutationCapability: Sendable {
    func deleteArchived(_ id: String) async throws
    func startNew() async throws -> String?
    func summarizeArchived(_ id: String) async throws
}

public protocol HistoryPresentationCapability: Sendable {
    func showHistory(invocation: any FunctionInput) async throws
}
