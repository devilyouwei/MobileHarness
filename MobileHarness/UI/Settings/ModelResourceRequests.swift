import Foundation

@MainActor public protocol ModelResourcesOperating: AnyObject {
    func refresh(generation: UInt64?) async throws -> ModelResourceViewSnapshot
    func restoreSource() async throws -> ModelResourceSourceDraft
    func saveSource(_ source: ModelResourceSourceDraft) async throws
    func download(_ id: String) async throws
    func cancel(_ id: String) async throws
    func remove(_ id: String) async throws
}

public struct ModelResourceSelectionError: LocalizedError, Sendable {
    public let group: ModelResourceGroup
    public init(group: ModelResourceGroup) { self.group = group }
    public var errorDescription: String? { group.installationMessage }
}
