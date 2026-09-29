import Foundation
import Observation
import StorageChat

@MainActor @Observable
public final class ConversationHistoryState {
    public var archive: ConversationArchive?
    public var status: String?
    public var isBusy = false
    public init() {}
}

@MainActor
public protocol ConversationHistoryControlling: AnyObject {
    func load() async
    func startNew()
    func summarize(_ id: UUID)
    func delete(_ id: UUID)
    func cancel()
    func preview(_ turn: ConversationRecord) -> String
}
