import Foundation
import StorageCore

public protocol AssistantConversationRepository: Sendable {
    var storageScope: UUID { get }
    func saveAuxiliaryRequest(dialog: String, request: AssistantModelRequest) async throws
    func current() async throws -> AssistantConversationRecord
    func listDialogs(before: Int64?, limit: Int) async throws -> [AssistantConversationRecord]
    func dialog(_ id: String) async throws -> AssistantConversationRecord
    func rotate(_ id: String) async throws -> AssistantConversationRecord
    func setTitle(_ title: String?, error: String?, dialog id: String) async throws
    func deleteDialog(_ id: String) async throws
}
