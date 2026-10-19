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
    private let autosaveDelay: Duration
    private var restoration: Task<Void, Never>?
    private var autosave: Task<Void, Never>?
    private var pendingEndpoint: String?
    private var autosaveDeadline: ContinuousClock.Instant?
    private var stopped = false
    public init(
        state: any ModelResourcesPresenting, operations: any ModelResourcesOperating,
        autosaveDelay: Duration = .milliseconds(600)
    ) {
        self.state = state
        self.operations = operations
        self.autosaveDelay = max(.zero, autosaveDelay)
    }
    deinit {
        restoration?.cancel()
        autosave?.cancel()
    }
    public func editDownloadSource(_ endpoint: String) {
        guard !stopped, state.source.endpoint != endpoint, state.present(.sourceEndpoint(endpoint)) else { return }
        pendingEndpoint = endpoint
        autosaveDeadline = .now.advanced(by: autosaveDelay)
        scheduleAutosave()
    }
    private func scheduleAutosave() {
        guard !stopped, state.hasRestored, pendingEndpoint != nil, autosave == nil else { return }
        autosave = Task { [weak self] in
            defer { self?.autosave = nil }
            while let deadline = self?.autosaveDeadline {
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                guard !Task.isCancelled, let self, !self.stopped else { return }
                if let current = self.autosaveDeadline, current > .now { continue }
                // A saving completion schedules the retained latest edit; never poll the UI.
                guard !self.state.saving else { return }
                self.pendingEndpoint = nil
                self.autosaveDeadline = nil
                _ = await self.saveDownloadSource()
            }
        }
    }
    private func finishSaving() {
        if let pendingEndpoint { state.present(.sourceEndpoint(pendingEndpoint)) }
        state.present(.saving(false))
        scheduleAutosave()
    }
    public func stopAndWait() async {
        stopped = true
        pendingEndpoint = nil
        autosaveDeadline = nil
        restoration?.cancel()
        autosave?.cancel()
        await restoration?.value
        await autosave?.value
        restoration = nil
        autosave = nil
    }
    private func restoreConfirmedSource() async throws -> ModelResourceSourceDraft {
        let value = try await operations.restoreSource()
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        confirmedSource = value
        preferenceFailed = false
        return value
    }
    public func restore() async {
        guard !stopped else { return }
        if let restoration { return await restoration.value }
        if state.hasRestored, !preferenceFailed {
            await refresh()
            return
        }
        let worker = Task {
            defer {
                restoration = nil
                scheduleAutosave()
            }
            do {
                let saved = try await restoreConfirmedSource()
                state.present(.source(saved))
                if let pendingEndpoint { state.present(.sourceEndpoint(pendingEndpoint)) }
                state.present(.hasRestored(true))
                await refresh()
            } catch {
                guard !Task.isCancelled, !stopped else { return }
                preferenceFailed = true
                recordCommandFailure(error)
            }
        }
        restoration = worker
        await worker.value
    }
    public func refresh() async {
        guard !stopped, !Task.isCancelled else { return }
        let generation = state.beginRefresh()
        do {
            _ = try await operations.refresh(generation: generation)
            guard !stopped, !Task.isCancelled, generation == state.refreshGeneration else { return }
            if !state.saving, !preferenceFailed {
                let saved = try await restoreConfirmedSource()
                state.present(.sourceUseCustomRecognition(saved.useCustomRecognition))
                state.present(.sourceUseCustomSynthesis(saved.useCustomSynthesis))
            }

        } catch {
            guard !stopped, !Task.isCancelled, generation == state.refreshGeneration else { return }
            preferenceFailed = true
            if case ApplicationControlIntentFailure.presented = error { return }
            state.present(.error(error.localizedDescription))
        }
    }
    public func acceptPresentedSnapshot() { admitted.subtract(state.items.map(\.id)) }
    public func saveSource() async {
        guard !stopped, !state.saving else { return }
        state.present(.saving(true))
        defer { finishSaving() }
        do {
            try await operations.saveSource(state.source)
            state.present(.source(try await restoreConfirmedSource()))
            state.present(.error(nil))
        } catch { await handleSaveFailure(error) }
    }
    /// Persist only the download endpoint; voice switches retain their durable values.
    @discardableResult public func saveDownloadSource() async -> Bool {
        guard !stopped, state.hasRestored, !state.saving else { return false }
        state.present(.saving(true))
        defer { finishSaving() }
        let endpoint = state.source.endpoint
        if pendingEndpoint == endpoint {
            pendingEndpoint = nil
            autosaveDeadline = nil
        }
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
        guard !stopped, !Task.isCancelled else { return }
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
        guard !stopped, !state.saving, group == .recognition || group == .synthesis else { return }
        state.present(.saving(true))
        defer { finishSaving() }
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
        guard !stopped, !Task.isCancelled else { return }
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
        _ = state.beginRefresh()
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
