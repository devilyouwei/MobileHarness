import ActionBindings
import Foundation
import PlatformKit
import UI

/// Root-owned interaction admission; persistence/model effects remain injected.
@MainActor public final class ModelResourceInteractionWorkflow: ModelResourcesControlling {
    public let state: any ModelResourcesPresenting
    private enum Operation { case download, remove }
    private var pending: [String: Operation] = [:] {
        didSet { state.present(.pending(pending.mapValues { $0 == .download ? .download : .remove })) }
    }
    private var admitted: Set<String> = [] { didSet { state.present(.admitted(admitted)) } }
    private var cancelling: Set<String> = [] { didSet { state.present(.cancelling(cancelling)) } }
    private var requests: [String: Task<Void, Error>] = [:]
    private var confirmedSource: ModelResourceSourceDraft?
    private var preferenceFailed = false
    private let operations: any ModelResourcesOperating
    public init(state: any ModelResourcesPresenting, operations: any ModelResourcesOperating) {
        self.state = state
        self.operations = operations
    }
    private func restoreConfirmedSource() async throws -> ModelResourceSourceDraft {
        let value = try await operations.restoreSource()
        confirmedSource = value
        preferenceFailed = false
        return value
    }
    public func restore() async {
        do {
            state.present(.source(try await restoreConfirmedSource()))
            state.present(.hasRestored(true))
            await refresh()
        } catch {
            preferenceFailed = true
            recordCommandFailure(error)
        }
    }
    public func refresh() async {
        let generation = state.beginRefresh()
        do {
            _ = try await operations.refresh(generation: generation)
            guard generation == state.refreshGeneration else { return }
            if !state.saving, !preferenceFailed {
                let saved = try await restoreConfirmedSource()
                state.present(.sourceUseCustomRecognition(saved.useCustomRecognition))
                state.present(.sourceUseCustomSynthesis(saved.useCustomSynthesis))
            }

        } catch {
            guard generation == state.refreshGeneration else { return }
            preferenceFailed = true
            if case ApplicationControlIntentFailure.presented = error { return }
            state.present(.error(error.localizedDescription))
        }
    }
    public func acceptPresentedSnapshot() { admitted.subtract(state.items.map(\.id)) }
    public func saveSource() async {
        guard !state.saving else { return }
        state.present(.saving(true))
        defer { state.present(.saving(false)) }
        do {
            try await operations.saveSource(state.source)
            state.present(.source(try await restoreConfirmedSource()))
            state.present(.error(nil))
        } catch { await handleSaveFailure(error) }
    }
    /// Persist only the download endpoint; voice switches retain their durable values.
    @discardableResult public func saveDownloadSource() async -> Bool {
        guard state.hasRestored, !state.saving else { return false }
        state.present(.saving(true))
        defer { state.present(.saving(false)) }
        let endpoint = state.source.endpoint
        do {
            var draft = try await restoreConfirmedSource()
            if draft.endpoint == endpoint && draft.allowsCellular {
                state.present(.error(nil))
                return true
            }
            draft.endpoint = endpoint
            draft.allowsCellular = true
            try await operations.saveSource(draft)
            let saved = try await restoreConfirmedSource()
            if state.source.endpoint == endpoint { state.present(.sourceEndpoint(saved.endpoint)) }
            state.present(.sourceAllowsCellular(true))
            state.present(.error(nil))
            return true
        } catch {
            preferenceFailed = true
            recordCommandFailure(error)
            return false
        }
    }
    private func handleSaveFailure(_ failure: any Error) async {
        preferenceFailed = true
        recordCommandFailure(failure)
        if failure is ModelResourceSelectionError {
            state.present(.installationNotice(failure.localizedDescription))
            state.present(.error(nil))
        }
        if let saved = confirmedSource {
            state.present(.sourceUseCustomRecognition(saved.useCustomRecognition))
            state.present(.sourceUseCustomSynthesis(saved.useCustomSynthesis))
        }
    }
    public func setCustomModel(_ group: ModelResourceGroup, enabled: Bool) async {
        guard !state.saving, group == .recognition || group == .synthesis else { return }
        state.present(.saving(true))
        defer { state.present(.saving(false)) }
        do {
            // A voice switch must not save or validate an unfinished download-domain edit.
            var draft = try await restoreConfirmedSource()
            if group == .recognition {
                draft.useCustomRecognition = enabled
                state.present(.sourceUseCustomRecognition(enabled))
            } else {
                draft.useCustomSynthesis = enabled
                state.present(.sourceUseCustomSynthesis(enabled))
            }
            try await operations.saveSource(draft)
            let saved = try await restoreConfirmedSource()
            state.present(.sourceUseCustomRecognition(saved.useCustomRecognition))
            state.present(.sourceUseCustomSynthesis(saved.useCustomSynthesis))
            state.present(.error(nil))
        } catch { await handleSaveFailure(error) }
    }
    private func recordCommandFailure(_ error: any Error) {
        if case ApplicationControlIntentFailure.presented = error { return }
        state.present(.error(error.localizedDescription))
    }
    private func isDownloading(_ item: ModelResourceItem) -> Bool {
        pending[item.id] == .download || admitted.contains(item.id) || (item.active && item.activity != .deleting)
    }
    private func isBusy(_ item: ModelResourceItem) -> Bool {
        pending[item.id] != nil || admitted.contains(item.id) || cancelling.contains(item.id) || item.active
    }
    public func perform(_ id: String, operation: ModelResourceOperation) async {
        guard let item = state.items.first(where: { $0.id == id }) else { return }
        if operation == .cancel {
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
                state.present(.error(nil))
                await refresh()
            } catch {
                recordCommandFailure(error)
                if admissionCompleted { admitted.insert(id) }
            }
            return
        }
        guard !isBusy(item) else { return }
        guard pending.count < 32 else {
            state.present(.error("同时提交的模型操作过多，请稍后重试"))
            return
        }
        let command: Operation
        switch operation {
        case .download:
            guard !item.installed else { return }
            if id != "yolo26n-pose" {
                guard await saveDownloadSource(), !isBusy(item) else { return }
            }
            command = .download
        case .remove: command = .remove
        case .cancel: return
        }
        pending[id] = command
        state.beginRefresh()
        state.present(.error(nil))
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
        } catch { recordCommandFailure(error) }
    }
}
