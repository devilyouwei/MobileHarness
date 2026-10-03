import Foundation
import Observation

public enum ModelResourceActivity: Sendable { case queued, downloading, installing, deleting }

public struct ModelResourceItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let revision: String
    public let installedBytes: Int64
    public let license: String
    public let bytes: Int64
    public let progress: Double
    public let installed: Bool
    public let active: Bool
    public let activity: ModelResourceActivity?
    public let failure: String?
    public init(
        id: String, name: String, status: String, bytes: Int64, progress: Double, installed: Bool, active: Bool,
        failure: String?, revision: String = "", installedBytes: Int64 = 0, license: String = "",
        activity: ModelResourceActivity? = nil
    ) {
        self.revision = revision
        self.installedBytes = installedBytes
        self.license = license
        self.id = id
        self.name = name
        self.status = status
        self.bytes = bytes
        self.progress = progress.isFinite ? max(0, min(1, progress)) : 0
        self.installed = installed
        self.active = active
        self.activity = activity
        self.failure = failure
    }
}
public struct ModelResourceSourceDraft: Codable, Sendable {
    public var endpoint: String
    public var allowsCellular: Bool
    public init(endpoint: String = "https://huggingface.co", allowsCellular: Bool = false) {
        self.endpoint = endpoint
        self.allowsCellular = allowsCellular
    }
}
@MainActor public protocol ModelResourcesOperating: AnyObject {
    func refresh() async throws -> [ModelResourceItem]
    func restoreSource() async throws -> ModelResourceSourceDraft
    func saveSource(_ source: ModelResourceSourceDraft) async throws
    func download(_ id: String) async throws
    func cancel(_ id: String) async throws
    func remove(_ id: String) async throws
}
@MainActor @Observable public final class ModelResourcesState {
    public var source = ModelResourceSourceDraft()
    public private(set) var items: [ModelResourceItem] = []
    public private(set) var error: String?
    public private(set) var saving = false
    private enum Operation { case download, remove }
    private var pending: [String: Operation] = [:]
    private var admitted: Set<String> = []
    private var cancelling: Set<String> = []
    @ObservationIgnored private var requests: [String: Task<Void, Error>] = [:]
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private let operations: any ModelResourcesOperating
    public init(operations: any ModelResourcesOperating) { self.operations = operations }
    public func restore() async {
        do {
            source = try await operations.restoreSource()
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    public func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        do {
            let updated = try await operations.refresh()
            guard generation == refreshGeneration else { return }
            items = updated
            admitted.subtract(updated.map(\.id))
        } catch {
            guard generation == refreshGeneration else { return }
            self.error = error.localizedDescription
        }
    }
    public func saveSource() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await operations.saveSource(source)
            source = try await operations.restoreSource()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    public func isDownloading(_ item: ModelResourceItem) -> Bool {
        pending[item.id] == .download || admitted.contains(item.id) || (item.active && item.activity != .deleting)
    }
    public func isBusy(_ item: ModelResourceItem) -> Bool {
        pending[item.id] != nil || admitted.contains(item.id) || cancelling.contains(item.id) || item.active
    }
    public func isCancelling(_ id: String) -> Bool { cancelling.contains(id) }
    public func status(_ item: ModelResourceItem) -> String {
        if cancelling.contains(item.id) { return "正在取消…" }
        if pending[item.id] == .remove { return "正在删除…" }
        if pending[item.id] == .download && !item.active { return "正在提交下载…" }
        if admitted.contains(item.id) && !item.active { return "正在下载，等待状态更新…" }
        return item.status
    }

    public func perform(_ id: String, operation: String) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if operation == "cancel" {
            guard isDownloading(item), !cancelling.contains(id), pending[id] != .remove else { return }
            cancelling.insert(id)
            defer {
                cancelling.remove(id)
                pending[id] = nil
                requests[id] = nil
            }
            var admissionCompleted = false
            do {
                // Admission must finish before cancellation; otherwise a late admission could restart the download.
                if let admission = requests[id] { try await admission.value }
                admissionCompleted = true
                try await operations.cancel(id)
                admitted.remove(id)
                error = nil
                await refresh()
            } catch {
                self.error = error.localizedDescription
                if admissionCompleted { admitted.insert(id) }
            }
            return
        }
        guard !isBusy(item) else { return }
        guard pending.count < 32 else {
            error = "同时提交的模型操作过多，请稍后重试"
            return
        }
        let command: Operation
        switch operation {
        case "download":
            guard !item.installed else { return }
            command = .download
        case "remove": command = .remove
        default: return
        }
        pending[id] = command
        refreshGeneration &+= 1
        error = nil
        let request = Task { @MainActor in
            switch command {
            case .download: try await operations.download(id)
            case .remove: try await operations.remove(id)
            }
        }
        requests[id] = request
        defer {
            if !cancelling.contains(id) {
                pending[id] = nil
                requests[id] = nil
            }
        }
        do {
            try await request.value
            if !cancelling.contains(id) {
                if command == .download, pending[id] == .download { admitted.insert(id) }
                await refresh()
            }
        } catch { self.error = error.localizedDescription }
    }
}
