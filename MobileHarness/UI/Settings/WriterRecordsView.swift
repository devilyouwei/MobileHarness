import Foundation

public struct WriterArtifactItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let state: String
    public let entry: String
    public init(id: String, title: String, state: String, entry: String) {
        self.id = id
        self.title = title
        self.state = state
        self.entry = entry
    }
}
public struct WriterArtifactFile: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let content: String
    public init(path: String, content: String) {
        self.path = path
        self.content = content
    }
}
public struct WriterArtifactSnapshot: Sendable {
    public let item: WriterArtifactItem
    public let files: [WriterArtifactFile]
    public init(item: WriterArtifactItem, files: [WriterArtifactFile]) {
        self.item = item
        self.files = files
    }
}
@MainActor public protocol WriterArtifactsControlling: AnyObject {
    func read(_ id: String) async throws -> WriterArtifactSnapshot
    func export(_ snapshot: WriterArtifactSnapshot, path: String?, pdf: Bool) async throws -> URL
    func discardExport() async throws
    func preview(_ snapshot: WriterArtifactSnapshot, path: String) async throws -> WriterFilePreview
    func closePreview() async throws
}
public struct WriterWorkspaceItem: Identifiable, Sendable, Codable {
    public let workspaceID: String
    public var id: String { workspaceID }
    public let title: String
    public let updatedAt: Date
    public var isDeleted = false
    public var startedAt: Date? = nil
    public var requestCount: Int = 0
    public init(workspaceID: String, title: String, updatedAt: Date) {
        self.workspaceID = workspaceID
        self.title = title
        self.updatedAt = updatedAt
    }
}
public struct WriterRequestItem: Identifiable, Sendable {
    public let id: String
    public let position: UInt64
    public let number: Int
    public let delegateID: String
    public let workspaceID: String?
    public let phase: String
    public let path: String?
    public let attempt: Int
    public let date: Date
    public let state: String
    public let title: String
    public init(
        id: String, position: UInt64, number: Int, delegateID: String, phase: String, path: String?, attempt: Int,
        date: Date, state: String, title: String = "Writing step", workspaceID: String? = nil
    ) {
        self.id = id
        self.position = position
        self.number = number
        self.delegateID = delegateID
        self.workspaceID = workspaceID
        self.phase = phase
        self.path = path
        self.attempt = attempt
        self.date = date
        self.state = state
        self.title = title
    }
    public var displayTitle: String { title + (attempt > 1 ? " (retry)" : "") }
    public var statusTitle: String { Self.statusTitle(state) }
    static func statusTitle(_ state: String) -> String {
        switch state {
        case "generating": "Generating"
        case "executing": "Running"
        case "completed": "Completed"
        case "failed": "Failed"
        case "cancelled": "Cancelled"
        case "interrupted": "Interrupted"
        default: "Unknown"
        }
    }
}
public struct WriterRequestPage: Sendable {
    public let items: [WriterRequestItem]
    public let nextPosition: UInt64?
    public init(items: [WriterRequestItem], nextPosition: UInt64?) {
        self.items = items
        self.nextPosition = nextPosition
    }
}
public struct WriterWorkspacePage: Sendable {
    public let items: [WriterWorkspaceItem]
    public let nextID: String?
    public init(items: [WriterWorkspaceItem], nextID: String?) {
        self.items = items
        self.nextID = nextID
    }
}

/// Page-local snapshots survive child navigation; only a successful explicit refresh replaces them.
struct WriterRecordPages<Item: Identifiable & Sendable, Cursor: Hashable & Sendable>: Sendable {
    private(set) var items: [Item] = []
    private(set) var next: Cursor?
    private(set) var hasLoaded = false
    var paging = HistoryPageLoading<Cursor>()
    mutating func apply(_ incoming: [Item], next: Cursor?, reset: Bool) throws {
        try Task.checkCancellation()
        if reset {
            items = incoming
            paging = .init()
        } else {
            for item in incoming {
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index] = item
                } else {
                    items.append(item)
                }
            }
        }
        self.next = next
        hasLoaded = true
    }
    mutating func replaceHead(_ incoming: [Item], replacing count: Int) throws {
        try Task.checkCancellation()
        items.replaceSubrange(..<count, with: incoming)
    }
    mutating func update(_ item: Item) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
    }
}
public struct WriterRequestFinalization: Sendable {
    public enum State: String, Sendable { case completed, failed }
    public let state: State
    public let result: String?
    public let error: String?
    public init(state: State, result: String?, error: String?) {
        self.state = state
        self.result = result
        self.error = error
    }
}
public struct WriterRequestDetails: Sendable {
    public let summary: WriterRequestItem
    public private(set) var request: HistoryModelRequest?
    public let fallbackInput: String
    public private(set) var toolSources: [String: String]
    public let finalization: WriterRequestFinalization?
    public init(
        summary: WriterRequestItem, request: HistoryModelRequest?, fallbackInput: String, toolSources: [String: String],
        finalization: WriterRequestFinalization?
    ) {
        self.summary = summary
        self.request = request
        self.fallbackInput = fallbackInput
        self.toolSources = toolSources
        self.finalization = finalization
    }
    public mutating func clearLogs() {
        if let request {
            self.request = WriterRecordPresentation.clearingLogs(request)
            if request.inputMessages == nil { toolSources = [:] }
        }
    }
}
public struct WriterDelegationItem: Identifiable, Sendable {
    public let id: String
    public let position: UInt64
    public let goal: String
    public let input: String
    public let sourceAgent: String
    public let sourceContext: String?
    public var waiting: String? = nil
    public let date: Date
    public let state: String
    public let result: String?
    public let failure: String?
    public let workspace: WriterWorkspaceItem?
    public var stateTitle: String {
        switch state {
        case "waiting_input": return "Waiting for input"
        case "paused": return "Paused"
        case "closing": return "Finishing"
        case "cleanup_failed": return "Cleanup failed"
        default: return WriterRequestItem.statusTitle(state)
        }
    }
    public init(
        id: String, position: UInt64, goal: String, input: String, sourceAgent: String, sourceContext: String?,
        date: Date, state: String, result: String?, failure: String?, workspace: WriterWorkspaceItem?
    ) {
        self.id = id
        self.position = position
        self.goal = goal
        self.input = input
        self.sourceAgent = sourceAgent
        self.sourceContext = sourceContext
        self.date = date
        self.state = state
        self.result = result
        self.failure = failure
        self.workspace = workspace
    }
}
public struct WriterDelegationPage: Sendable {
    public let items: [WriterDelegationItem]
    public let next: UInt64?
    public let total: Int
    public init(items: [WriterDelegationItem], next: UInt64?, total: Int) {
        self.items = items
        self.next = next
        self.total = total
    }
}
@MainActor public protocol WriterRecordsControlling: AnyObject {
    func delegations(before: UInt64?) async throws -> WriterDelegationPage
    func delegation(_ id: String) async throws -> WriterDelegationItem
    func preflight(_ id: String, after: UInt64) async throws -> WriterRequestPage
    func workspaces(before: String?) async throws -> WriterWorkspacePage
    func workspace(_ id: String) async throws -> WriterWorkspaceItem
    func requests(workspaceID: String, after: UInt64) async throws -> WriterRequestPage
    func requests(workspaceID: String, before: UInt64?) async throws -> WriterRequestPage
    func requestDetail(_ id: String) async throws -> WriterRequestDetails
    func shareWorkspace(_ id: String) async throws -> String
    func clearRequestLogs(requestID: String?) async throws
}
public struct WriterFilePreview: Sendable {
    public let url: URL
    public let root: URL
    public init(url: URL, root: URL) {
        self.url = url
        self.root = root
    }
}
public enum WriterRecordPresentation {
    public static func contentPath(_ request: HistoryModelRequest) -> String? {
        guard let path = request.producerMetadata?["path"],
            !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return path
    }
    public static func tools(_ request: HistoryModelRequest) throws -> [HistoryFunctionRegistration]? {
        guard let metadata = request.decisionMetadata else { return nil }
        return try ConversationHistoryPresentation.functionCatalog(metadata.catalogJSON).tools
    }
    public static func promptMessages(_ request: HistoryModelRequest) -> [HistoryMessage] {
        guard request.logsCleared != true else { return [] }
        for source in [request.requestParametersJSON, request.requestJSON] {
            if let json = HistoryRecordedImages.messagesJSON(source),
                let messages = try? JSONDecoder().decode([HistoryMessage].self, from: Data(json.utf8))
            {
                return messages
            }
        }
        return []
    }
    /// The current input is the user/tool suffix after the latest model response, not earlier history.
    public static func inputMessages(_ messages: [HistoryMessage]) -> [HistoryMessage] {
        let start = messages.lastIndex(where: { $0.role == .assistant }).map { $0 + 1 } ?? 0
        return messages.dropFirst(start).filter { $0.role == .user || $0.role == .tool }
    }
    public static func requestInputs(_ request: HistoryModelRequest) -> [HistoryMessage] {
        request.inputMessages ?? inputMessages(promptMessages(request))
    }
    private struct DraftChange: Decodable {
        let path: String
        let firstChangedLine: String
        let beforeBytes: String
        let afterBytes: String
        let status: String
    }
    static func inputSummary(_ content: String, isTool: Bool) -> String {
        if isTool, content.utf8.count <= 16_384,
            let changes = try? JSONDecoder().decode([DraftChange].self, from: Data(content.utf8)),
            !changes.isEmpty, changes.allSatisfy({ $0.status == "draft edited; render before finish" })
        {
            let summary = changes.prefix(2).map {
                "\($0.path) · Draft changed, pending render\n\($0.beforeBytes) → \($0.afterBytes) bytes · First changed line \($0.firstChangedLine)"
            }.joined(separator: "\n")
            return changes.count <= 2 ? summary : summary + "\n\(changes.count) files"
        }
        let excerpt = content.prefix(240)
        return String(excerpt) + (excerpt.endIndex == content.endIndex ? "" : "…")
    }
    static func toolState(_ calls: [HistoryToolCall]) -> HistoryToolCall.State? {
        [.failed, .cancelled, .received, .completed].first { state in calls.contains { $0.state == state } }
    }
    static func toolStateTitle(_ state: HistoryToolCall.State) -> String {
        switch state {
        case .received: "Pending"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
    static func clearingLogs(_ request: HistoryModelRequest) -> HistoryModelRequest {
        HistoryModelRequest(
            producerMetadata: request.producerMetadata, inputMessages: request.inputMessages, logsCleared: true,
            messageID: request.messageID, isObservation: request.isObservation,
            historyOrder: request.historyOrder, id: request.id, date: request.date, input: request.input,
            requestJSON: "[]", historyTaskID: request.historyTaskID, decisionMetadata: request.decisionMetadata,
            modelRequestStartedAt: nil, firstTokenLatency: nil, firstTokenAt: nil, response: request.response,
            toolCalls: request.toolCalls, tokenUsage: nil, state: request.state, finishReason: nil, error: nil)
    }

    public static func firstToken(_ request: HistoryModelRequest) -> String {
        guard let latency = request.firstTokenLatency, latency.isFinite, latency >= 0 else {
            return "Time to first token: Unknown"
        }
        return "Time to first token: \(String(format: "%.3f", latency)) sec"
    }
    public static func requestDuration(_ request: HistoryModelRequest, at now: Date) -> String {
        let end = request.modelRequestCompletedAt ?? (request.state == .generating ? now : nil)
        guard let end else { return "Total duration: Unknown" }
        let elapsed = max(0, end.timeIntervalSince(request.modelRequestStartedAt ?? request.date))
        return "Total duration: \(String(format: "%.3f", elapsed)) sec"
    }
}
#if os(iOS)
    import SwiftUI
    import UIKit

    @MainActor public struct WriterRecordsView: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        private let controls: any WriterRecordsControlling
        private let artifacts: any WriterArtifactsControlling
        @State private var pages = WriterRecordPages<WriterWorkspaceItem, String>()
        private var items: [WriterWorkspaceItem] { pages.items }
        @State private var failure: String?
        @State private var loading = false
        @State private var refreshOffset = 0
        @State private var clearingLogs = false
        @State private var delegationTotal = 0
        public init(controls: any WriterRecordsControlling, artifacts: any WriterArtifactsControlling) {
            self.controls = controls
            self.artifacts = artifacts
        }
        public var body: some View {
            List {
                if let failure { Text(failure).foregroundStyle(.red) }
                Section {
                    NavigationLink {
                        WriterDelegationsView(controls: controls, artifacts: artifacts)
                    } label: {
                        LabeledContent(appCopy.text("Assignments"), value: String(delegationTotal))
                    }.accessibilityIdentifier("writer.delegations")
                }
                Section(appCopy.text("Workspace")) {
                    ForEach(items) { item in
                        NavigationLink {
                            WriterWorkspaceDetail(seed: item, controls: controls, artifacts: artifacts).id(item.id)
                        } label: {
                            HistoryRecordRow(
                                title: item.title, icon: "pencil.and.outline",
                                tint: Color(red: 0.65, green: 0.5, blue: 0.82)
                            ) {
                                ViewThatFits(in: .horizontal) {
                                    metadata(item, stacked: false)
                                    metadata(item, stacked: true)
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .accessibilityIdentifier("writer.workspace." + item.id)
                    }
                    if items.isEmpty && !loading && failure == nil { Text(appCopy.text("No workspaces yet")) }
                    if !pages.hasLoaded || pages.next != nil {
                        Button(loading ? appCopy.text("Loading…") : "Load More") { Task { await load(reset: false) } }
                            .disabled(loading)
                    }
                }
            }.navigationTitle(appCopy.text("My Writer")).navigationBarTitleDisplayMode(.inline).task {
                if !pages.hasLoaded { await load(reset: true) }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(2))
                        try await refreshWorkspaces()
                    } catch is CancellationError { return } catch {
                        failure = "Could not update records: \(error)"
                        return
                    }
                }
            }.refreshable { await load(reset: true) }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(appCopy.text("Clear request logs"), systemImage: "trash") { clearingLogs = true }
                    }
                }
                .confirmationDialog(
                    appCopy.text("Clear all request logs?"), isPresented: $clearingLogs, titleVisibility: .visible
                ) {
                    Button(appCopy.text("Clear all logs"), role: .destructive) {
                        Task {
                            do { try await controls.clearRequestLogs(requestID: nil) } catch {
                                failure = "Could not clear logs: \(error)"
                            }
                        }
                    }
                } message: {
                    Text(
                        appCopy.text(
                            "Deletes all Assistant and Writer request logs. Tasks, workspaces, messages, and other details are kept."
                        ))
                }
        }
        @ViewBuilder private func metadata(_ item: WriterWorkspaceItem, stacked: Bool) -> some View {
            if stacked {
                VStack(alignment: .leading, spacing: 4) {
                    workspaceFacts(item)
                    workspaceDate(item).frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: 8) {
                    workspaceFacts(item).fixedSize()
                    Spacer(minLength: 0)
                    workspaceDate(item)
                }
            }
        }
        private func workspaceFacts(_ item: WriterWorkspaceItem) -> some View {
            HStack(spacing: 5) {
                Text(item.id)
                Text("·")
                Text("\(item.requestCount) messages")

            }
        }
        private func workspaceDate(_ item: WriterWorkspaceItem) -> some View {
            Text(HistoryListPresentation.date(item.updatedAt))
                .fixedSize()
                .accessibilityLabel("Last updated " + item.updatedAt.formatted(date: .complete, time: .shortened))
        }
        private func refreshWorkspaces() async throws {
            guard !loading else { return }
            delegationTotal = try await controls.delegations(before: nil).total
            guard !items.isEmpty else { return }
            let targets = Array(items.dropFirst(refreshOffset).prefix(20))
            for item in targets {
                try Task.checkCancellation()
                let updated = try await controls.workspace(item.id)
                try Task.checkCancellation()
                pages.update(updated)
            }
            refreshOffset = items.isEmpty ? 0 : (refreshOffset + 20) % items.count
        }
        private func load(reset: Bool) async {
            guard !loading else { return }
            loading = true
            defer { loading = false }
            do {
                delegationTotal = try await controls.delegations(before: nil).total
                let page = try await controls.workspaces(before: reset ? nil : pages.next)
                try Task.checkCancellation()
                try pages.apply(page.items, next: page.nextID, reset: reset)
                if reset { refreshOffset = 0 }
                failure = nil
            } catch is CancellationError {} catch { failure = "Could not load: \(error)" }
        }
    }
    @MainActor private struct WriterRecordPagingFooter<Item: Identifiable & Sendable>: View {
        let cursor: UInt64
        @Binding var pages: WriterRecordPages<Item, UInt64>
        @Binding var reading: Bool
        let read: @MainActor (UInt64) async throws -> (items: [Item], next: UInt64?)
        var body: some View {
            HistoryPagingFooter(cursor: cursor, state: pages.paging, enabled: !reading || pages.paging.isLoading) {
                retry in await load(before: cursor, retry: retry)
            }
        }
        private func load(before cursor: UInt64, retry: Bool) async {
            guard !reading, pages.next == cursor, !Task.isCancelled,
                let ticket = pages.paging.begin(after: cursor, retry: retry)
            else { return }
            reading = true
            defer { reading = false }
            do {
                let page = try await read(cursor)
                try pages.apply(page.items, next: page.next, reset: false)
                pages.paging.finish(ticket)
            } catch is CancellationError {
                pages.paging.cancel(ticket)
            } catch {
                pages.paging.finish(ticket, error: "Could not load: \(error)")
            }
        }
    }
    @MainActor private struct WriterDelegationsView: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        let controls: any WriterRecordsControlling
        let artifacts: any WriterArtifactsControlling
        @State private var pages = WriterRecordPages<WriterDelegationItem, UInt64>()
        @State private var reading = false
        @State private var failure: String?
        var body: some View {
            List {
                if let failure { Text(failure).foregroundStyle(.red) }
                ForEach(pages.items) { item in
                    NavigationLink {
                        WriterDelegationDetail(seed: item, controls: controls, artifacts: artifacts)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.goal).lineLimit(2)
                            Text(item.sourceAgent + " · " + item.date.formatted() + " · " + item.state).font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("writer.delegation." + item.id)
                }
                if let cursor = pages.next {
                    WriterRecordPagingFooter(cursor: cursor, pages: $pages, reading: $reading) { before in
                        let page = try await controls.delegations(before: before)
                        return (page.items, page.next)
                    }
                }
            }.navigationTitle(appCopy.text("Assignments")).task { if !pages.hasLoaded { await load() } }.refreshable {
                await load()
            }
        }
        private func load() async {
            guard !reading else { return }
            reading = true
            defer { reading = false }
            do {
                let page = try await controls.delegations(before: nil)
                try pages.apply(page.items, next: page.next, reset: true)
                failure = nil
            } catch is CancellationError {} catch { failure = String(describing: error) }
        }
    }
    @MainActor private struct WriterDelegationDetail: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        let seed: WriterDelegationItem
        let controls: any WriterRecordsControlling
        let artifacts: any WriterArtifactsControlling
        @State private var current: WriterDelegationItem?
        @State private var pages = WriterRecordPages<WriterRequestItem, UInt64>()
        @State private var reading = false
        @State private var failure: String?
        private var item: WriterDelegationItem { current ?? seed }
        var body: some View {
            List {
                Section(appCopy.text("Assignment")) {
                    LabeledContent(appCopy.text("Source Agent"), value: item.sourceAgent)
                    if let source = item.sourceContext {
                        LabeledContent(appCopy.text("Source conversation"), value: source)
                    }
                    LabeledContent(appCopy.text("Received at"), value: item.date.formatted())
                    LabeledContent(appCopy.text("Status"), value: appCopy.text(item.stateTitle))
                    Text(item.goal)
                }
                if let waiting = item.waiting { Section(appCopy.text("Waiting for input")) { Text(verbatim: waiting) } }
                Section(appCopy.text("Original input")) { Text(verbatim: item.input).textSelection(.enabled) }
                if let result = item.result {
                    Section(appCopy.text("Result")) { Text(verbatim: result).textSelection(.enabled) }
                }
                if let error = item.failure {
                    Section(appCopy.text("Failed")) { Text(verbatim: error).foregroundStyle(.red) }
                }
                if let workspace = item.workspace {
                    Section(appCopy.text("Workspace")) {
                        NavigationLink {
                            WriterWorkspaceDetail(seed: workspace, controls: controls, artifacts: artifacts)
                        } label: {
                            Text(workspace.title + (workspace.isDeleted ? appCopy.text(" (deleted)") : ""))
                        }
                    }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
                Section(appCopy.text("Messages before entering the workspace")) {
                    ForEach(pages.items) { row in
                        NavigationLink {
                            WriterRequestDetail(requestID: row.id, controls: controls)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(row.displayTitle)
                                Text(row.date.formatted()).font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("writer.preflight.request." + row.id)
                    }
                    if let next = pages.next {
                        Button(appCopy.text("Load more")) { Task { await load(after: next, reset: false) } }.disabled(
                            reading)
                    }
                }
            }.navigationTitle(appCopy.text("Assignment details")).task {
                if !pages.hasLoaded { await load(after: 0, reset: true) }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(2))
                        current = try await controls.delegation(seed.id)
                        if pages.next == nil {
                            let rows = pages.items
                            await load(after: rows.count > 20 ? rows[rows.count - 21].position : 0, reset: false)
                        }
                    } catch { return }
                }
            }.refreshable { await load(after: 0, reset: true) }
        }
        private func load(after: UInt64, reset: Bool) async {
            guard !reading else { return }
            reading = true
            defer { reading = false }
            do {
                let updated = try await controls.delegation(seed.id)
                let page = try await controls.preflight(seed.id, after: after)
                try pages.apply(page.items, next: page.nextPosition, reset: reset)
                current = updated
                failure = nil
            } catch is CancellationError {} catch { failure = String(describing: error) }
        }
    }
    @MainActor private struct WriterWorkspaceDetail: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        let seed: WriterWorkspaceItem
        let controls: any WriterRecordsControlling
        let artifacts: any WriterArtifactsControlling
        @State private var current: WriterWorkspaceItem?
        @State private var pages = WriterRecordPages<WriterRequestItem, UInt64>()
        private var items: [WriterRequestItem] { pages.items }
        @State private var failure: String?
        @State private var sharing: String?
        @State private var showsShare = false
        @State private var sharingBusy = false
        @State private var reading = false
        var body: some View {
            List {
                Section {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "pencil.and.outline").foregroundStyle(.purple)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            Text((current ?? seed).id).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(verbatim: (current ?? seed).title).font(.body).foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("writer.workspace.title")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let date = (current ?? seed).startedAt {
                        LabeledContent(
                            appCopy.text("Started at"), value: date.formatted(date: .abbreviated, time: .standard)
                        )
                        .accessibilityIdentifier("writer.workspace.started")
                    }
                    LabeledContent(
                        appCopy.text("Updated at"),
                        value: (current ?? seed).updatedAt.formatted(date: .abbreviated, time: .standard)
                    )
                    .accessibilityIdentifier("writer.workspace.updated")
                    LabeledContent(appCopy.text("Message count"), value: String((current ?? seed).requestCount))
                    if (current ?? seed).isDeleted {
                        LabeledContent(appCopy.text("Status"), value: appCopy.text("Workspace deleted"))
                    }
                    if !(current ?? seed).isDeleted {
                        let project = seed.workspaceID
                        NavigationLink {
                            WriterArtifactDetail(
                                item: .init(id: project, title: seed.title, state: "draft", entry: "index.html"),
                                controls: artifacts)
                        } label: {
                            Label(appCopy.text("Browse files"), systemImage: "folder")
                        }.accessibilityIdentifier("writer.workspace.files")
                    } else {
                        Label(appCopy.text("No project directory yet"), systemImage: "folder").foregroundStyle(
                            .secondary)
                    }

                }
                if let failure { Text(failure).foregroundStyle(.red) }
                Section(appCopy.text("Workspace messages")) {
                    ForEach(items) { item in
                        NavigationLink {
                            WriterRequestDetail(requestID: item.id, controls: controls)
                        } label: {
                            HStack(alignment: .center, spacing: 12) {
                                Text(String(item.number)).font(
                                    .system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit()
                                )
                                .frame(minWidth: 34, minHeight: 36).padding(.horizontal, 3)
                                .foregroundStyle(numberTint(item))
                                .background(numberTint(item).opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityLabel("Round \(item.number)")
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(verbatim: item.displayTitle).font(.body).foregroundStyle(.primary)
                                        .lineLimit(2).truncationMode(.tail)
                                    HStack(spacing: 8) {
                                        Text(item.date, format: .dateTime.month().day().hour().minute().second())
                                            .foregroundStyle(.secondary).lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text(appCopy.text(item.statusTitle)).padding(.horizontal, 6).padding(
                                            .vertical, 2
                                        )
                                        .foregroundStyle(stateTint(item.state))
                                        .background(stateTint(item.state).opacity(0.12), in: Capsule()).fixedSize()
                                    }.font(.caption2)
                                }
                            }.padding(.vertical, 3)
                        }.accessibilityIdentifier("writer.request." + item.id)
                    }
                    if let cursor = pages.next {
                        WriterRecordPagingFooter(cursor: cursor, pages: $pages, reading: $reading) { before in
                            let page = try await controls.requests(workspaceID: seed.id, before: before)
                            return (page.items, page.nextPosition)
                        }
                    }
                }
            }.navigationTitle(appCopy.text("Workspace"))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(appCopy.text("Export"), systemImage: "square.and.arrow.up") { showsShare = true }
                            .labelStyle(.iconOnly)
                            .disabled(sharingBusy)
                            .accessibilityLabel(appCopy.text("Export workspace records"))
                            .accessibilityIdentifier("writer.workspace.export")
                    }
                }
                .task {
                    if !pages.hasLoaded { await load() }
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .seconds(2))
                            await refreshVisible()
                        } catch is CancellationError { return } catch {
                            failure = "Could not update records: \(error)"
                            return
                        }
                    }
                }.refreshable { await load() }
                .sheet(isPresented: $showsShare) {
                    Group {
                        if let sharing {
                            WriterTextShare(text: sharing)
                        } else {
                            ProgressView(appCopy.text("Exporting…"))
                        }
                    }
                    .task {
                        guard !sharingBusy else { return }
                        sharingBusy = true
                        defer { sharingBusy = false }
                        do { sharing = try await controls.shareWorkspace(seed.id) } catch is CancellationError {
                        } catch {
                            failure = "Export failed: \(error)"
                            showsShare = false
                        }
                    }
                }
        }
        private func stateTint(_ state: String) -> Color {
            switch state {
            case "failed": .red
            case "cancelled": .secondary
            case "interrupted": .orange
            case "completed": .green
            default: .blue
            }
        }
        private func numberTint(_ item: WriterRequestItem) -> Color {
            item.state == "failed" ? .red : .gray
        }
        private func refreshVisible() async {
            guard !reading else { return }
            guard !items.isEmpty else {
                await load()
                return
            }
            reading = true
            defer { reading = false }
            // Read a contiguous ascending batch after the anchor, leaving room for new messages.
            let count = min(10, items.count)
            let after = items.count > count ? items[count].position : 0
            do {
                let updated = try await controls.workspace(seed.id)
                let page = try await controls.requests(workspaceID: seed.id, after: after)
                try pages.replaceHead(Array(page.items.reversed()), replacing: count)
                current = updated
                failure = nil
            } catch is CancellationError {} catch { failure = "Could not update records: \(error)" }
        }
        private func load() async {
            guard !reading else { return }
            reading = true
            defer { reading = false }
            do {
                let updated = try await controls.workspace(seed.id)
                let page = try await controls.requests(workspaceID: seed.id, before: nil)
                try pages.apply(page.items, next: page.nextPosition, reset: true)
                current = updated
                failure = nil
            } catch is CancellationError {} catch { failure = "Could not load: \(error)" }
        }
    }
    @MainActor private struct WriterRequestDetail: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        let requestID: String
        let controls: any WriterRecordsControlling
        @State private var detail: WriterRequestDetails?
        @State private var failure: String?
        @State private var confirmsClearing = false
        @State private var reading = false
        @State private var clearing = false

        var body: some View {
            List {
                if let failure { Text(failure).foregroundStyle(.red) }
                if let detail {
                    WriterRequestSections(
                        detail: detail, controls: controls, canClearLogs: !reading
                    ) {
                        confirmsClearing = true
                    }.disabled(clearing)
                } else if failure == nil {
                    ProgressView()
                }
            }
            .navigationTitle(appCopy.text("Request details"))
            .task { await load() }
            .refreshable { await load() }
            .confirmationDialog(
                appCopy.text("Clear this request log?"), isPresented: $confirmsClearing, titleVisibility: .visible
            ) {
                Button(appCopy.text("Clear log"), role: .destructive) { Task { await clearLogs() } }
            }
        }

        private func load() async {
            guard !reading, !clearing else { return }
            reading = true
            defer { reading = false }
            do {
                let result = try await controls.requestDetail(requestID)
                try Task.checkCancellation()
                detail = result
                failure = nil
            } catch is CancellationError {} catch {
                failure = "Could not load: \(error)"
            }
        }

        private func clearLogs() async {
            guard !reading, !clearing, detail?.request?.logsCleared == false else { return }
            clearing = true
            defer { clearing = false }
            do {
                try await controls.clearRequestLogs(requestID: requestID)
                detail?.clearLogs()
                failure = nil
            } catch {
                failure = "Could not clear logs: \(error)"
            }
        }
    }

    @MainActor private struct WriterRequestSections: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        let detail: WriterRequestDetails
        let controls: any WriterRecordsControlling
        let canClearLogs: Bool
        let clearLogs: () -> Void

        var body: some View {
            overview
            Section(appCopy.text("Input for this round")) {
                let inputs = detail.request.map(WriterRecordPresentation.requestInputs) ?? []
                if inputs.isEmpty {
                    inputRow(detail.fallbackInput, title: appCopy.text("Input"))
                } else {
                    ForEach(Array(inputs.enumerated()), id: \.offset) { _, message in
                        inputRow(
                            message.content,
                            title: message.role == .tool ? appCopy.text("Tool feedback") : appCopy.text("User input"),
                            message: message)
                    }
                }
                if let request = detail.request { tools(request) }
            }
            if let request = detail.request, !request.toolCalls.isEmpty {
                Section(appCopy.text("Tool calls for this round")) {
                    ForEach(request.toolCalls) { call in
                        WriterRequestToolCard(call: call)
                    }
                }
            }
            output
            if let request = detail.request { logs(request) }
        }

        private var overview: some View {
            let summary = detail.summary
            return Section(appCopy.text("Round overview")) {
                Text(appCopy.format("Round %@ · %@", String(summary.number), appCopy.text(summary.title))).font(
                    .headline
                )
                .accessibilityIdentifier("writer.detail.overview")
                LabeledContent(appCopy.text("Phase"), value: summary.phase)
                if let id = summary.workspaceID {
                    WriterRecordIdentifier(label: appCopy.text("Workspace ID"), value: id)
                }
                if let path = summary.path { LabeledContent(appCopy.text("Target file"), value: path) }
                if summary.attempt > 1 { LabeledContent(appCopy.text("Attempts"), value: String(summary.attempt)) }
                if let request = detail.request {
                    LabeledContent(appCopy.text("Model"), value: WriterRequestItem.statusTitle(request.state.rawValue))
                        .accessibilityIdentifier("writer.detail.model-state")
                    if let tool = WriterRecordPresentation.toolState(request.toolCalls) {
                        LabeledContent(appCopy.text("Tool"), value: WriterRecordPresentation.toolStateTitle(tool))
                            .accessibilityIdentifier("writer.detail.tool-state")
                    }
                    LabeledContent(appCopy.text("Request time")) {
                        Text(summary.date, format: .dateTime.year().month().day().hour().minute().second())
                    }
                    WriterRecordIdentifier(label: appCopy.text("Request ID"), value: request.id)
                } else {
                    LabeledContent(appCopy.text("Recorded at")) {
                        Text(summary.date, format: .dateTime.year().month().day().hour().minute().second())
                    }
                }
            }
        }

        @ViewBuilder private func inputRow(_ content: String, title: String, message: HistoryMessage? = nil)
            -> some View
        {
            let isTool = message?.role == .tool
            DisclosureGroup {
                WriterRecordedText(content)
                if let id = message?.toolCallID {
                    WriterRecordIdentifier(label: appCopy.text("Source call ID"), value: id)
                }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(isTool && message?.toolName != nil ? "\(title) · \(message?.toolName ?? "")" : title)
                    Text(verbatim: WriterRecordPresentation.inputSummary(content, isTool: isTool))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(isTool ? 5 : 3)
                }
            }
            if let call = message?.toolCallID, let source = detail.toolSources[call] {
                NavigationLink {
                    WriterRequestDetail(requestID: source, controls: controls)
                } label: {
                    Text(appCopy.text("View source call"))
                }.accessibilityIdentifier("writer.detail.tool-source")
            }
        }

        @ViewBuilder private func tools(_ request: HistoryModelRequest) -> some View {
            switch Result(catching: { try WriterRecordPresentation.tools(request) }) {
            case .success(let entries?):
                DisclosureGroup("Available tools (\(entries.count))") {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        HistoryCatalogEntryRow(entry: entry)
                    }
                }.accessibilityIdentifier("writer.request.tools")
                    .disabled(entries.isEmpty)
            case .success(nil):
                LabeledContent(appCopy.text("Available tools"), value: appCopy.text("Unrecorded"))
            case .failure:
                LabeledContent(appCopy.text("Available tools"), value: appCopy.text("Could not read"))
            }
        }

        @ViewBuilder private var output: some View {
            let content = detail.request.flatMap { $0.response.isEmpty ? nil : $0 }
            if content != nil || detail.finalization != nil {
                Section(appCopy.text("Output for this round")) {
                    if let content {
                        let path = WriterRecordPresentation.contentPath(content)
                        DisclosureGroup {
                            WriterRecordedText(content.response).accessibilityIdentifier("writer.request.source")
                        } label: {
                            Label(
                                path ?? appCopy.text("Generated text"),
                                systemImage: path == nil ? "text.alignleft" : "doc.text")
                        }.accessibilityIdentifier("writer.request.content.toggle")
                    }
                    if let finalization = detail.finalization {
                        let status =
                            finalization.state == .completed ? appCopy.text("Succeeded") : appCopy.text("Failed")
                        if let evidence = finalization.error ?? finalization.result, !evidence.isEmpty {
                            DisclosureGroup(appCopy.text("Host cleanup · ") + status) { WriterRecordedText(evidence) }
                        } else {
                            LabeledContent(appCopy.text("Host cleanup"), value: status)
                        }
                    }
                }
            }
        }

        private func logs(_ request: HistoryModelRequest) -> some View {
            Section(appCopy.text("Debug log")) {
                if request.logsCleared == true {
                    Text(appCopy.text("Log cleared")).foregroundStyle(.secondary)
                        .accessibilityIdentifier("writer.prompts.cleared")
                } else {
                    DisclosureGroup(appCopy.text("Full prompts")) {
                        ForEach(HistoryRecordedImages.references(request.requestParametersJSON)) { reference in
                            WriterRequestImage(
                                recorded: HistoryRecordedImages.data(reference.id, json: request.requestParametersJSON))
                        }
                        let messages = WriterRecordPresentation.promptMessages(request)
                        if messages.isEmpty { Text(appCopy.text("Unrecorded")).foregroundStyle(.secondary) }
                        HistoryPromptItems(messages: messages)
                    }
                    DisclosureGroup(appCopy.text("Generation metrics")) {
                        LabeledContent(
                            appCopy.text("Model name"),
                            value: request.model.flatMap { $0.isEmpty ? nil : $0 } ?? appCopy.text("Unrecorded"))
                        LabeledContent(
                            appCopy.text("Output token limit"),
                            value: request.maximumOutputTokens?.formatted() ?? appCopy.text("Unrecorded"))
                        LabeledContent(
                            "Temperature", value: request.temperature?.formatted() ?? appCopy.text("Unrecorded"))
                        Text(WriterRecordPresentation.firstToken(request)).accessibilityIdentifier(
                            "writer.request.ttft")
                        Text(WriterRecordPresentation.requestDuration(request, at: .now)).accessibilityIdentifier(
                            "writer.request.duration")
                        LabeledContent(
                            appCopy.text("Finish reason"), value: request.finishReason ?? appCopy.text("Unrecorded"))
                        if let usage = request.tokenUsage {
                            LabeledContent(
                                appCopy.text("Input / Output / Total tokens"),
                                value: "\(usage.input) / \(usage.generated) / \(usage.total)")
                            if let cached = usage.cachedInput {
                                LabeledContent(appCopy.text("Cache read tokens"), value: cached.formatted())
                            }
                            if let written = usage.cacheWriteInput {
                                LabeledContent(appCopy.text("Cache write tokens"), value: written.formatted())
                            }
                        } else {
                            LabeledContent(appCopy.text("Token usage"), value: appCopy.text("Unrecorded"))
                        }
                        if let diagnostic = request.failureDiagnostic {
                            WriterFailureDetail(diagnostic: diagnostic)
                        } else if let error = request.error {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }.accessibilityIdentifier("writer.detail.generation")
                    Button(appCopy.text("Clear this request log"), role: .destructive, action: clearLogs)
                        .disabled(!canClearLogs)
                        .accessibilityIdentifier("writer.detail.clear-logs")
                }
            }
        }
    }

    @MainActor private struct WriterRequestToolCard: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        let call: HistoryToolCall

        var body: some View {
            let arguments =
                (try? JSONDecoder().decode([String: String].self, from: Data(call.argumentsJSON.utf8))) ?? [:]
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent {
                    Text(WriterRecordPresentation.toolStateTitle(call.state))
                        .foregroundStyle(call.state == .failed ? Color.red : Color.secondary)
                } label: {
                    Text(verbatim: call.name)
                        .font(.headline)
                }
                if let path = arguments["path"] ?? arguments["entry"] ?? arguments["workspaceID"] {
                    LabeledContent(appCopy.text("Goal"), value: path)
                }
                if let destination = arguments["destination"] {
                    LabeledContent(appCopy.text("Destination path"), value: destination)
                }
                DisclosureGroup(appCopy.text("Arguments")) { WriterRecordedText(call.argumentsJSON) }
                if let output = call.output {
                    DisclosureGroup(appCopy.text("Result")) { WriterRecordedText(output) }
                } else {
                    LabeledContent(
                        appCopy.text("Result"),
                        value: call.state == .received ? appCopy.text("Pending") : appCopy.text("Unrecorded"))
                }
                WriterRecordIdentifier(label: appCopy.text("Call ID"), value: call.providerID)
                if let diagnostic = call.failureDiagnostic {
                    WriterFailureDetail(diagnostic: diagnostic)
                } else if let error = call.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
    }

    @MainActor private struct WriterRecordIdentifier: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        let label: String
        let value: String
        var body: some View {
            LabeledContent {
                HStack {
                    Text(verbatim: value).font(.system(.caption, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Button(appCopy.text("Copy") + label, systemImage: "document.on.document") {
                        UIPasteboard.general.string = value
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            } label: {
                Text(label)
            }
        }
    }

    private struct WriterRecordedText: View {
        let value: String
        init(_ value: String) { self.value = value }
        var body: some View {
            Text(verbatim: value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    @MainActor private struct WriterFailureDetail: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        let diagnostic: HistoryFailureDiagnostic
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(diagnostic.message).foregroundStyle(.red).textSelection(.enabled)
                LabeledContent(appCopy.text("Category"), value: diagnostic.category)
                LabeledContent(appCopy.text("Phase"), value: diagnostic.stage)
                LabeledContent(appCopy.text("Error code"), value: diagnostic.code)
                ForEach(diagnostic.details.keys.sorted(), id: \.self) { key in
                    LabeledContent(key, value: diagnostic.details[key] ?? "").textSelection(.enabled)
                }
                ForEach(Array(diagnostic.causes.enumerated()), id: \.offset) { index, cause in
                    DisclosureGroup("Related cause \(index + 1)") {
                        Text(cause.message).foregroundStyle(.red).textSelection(.enabled)
                        LabeledContent(appCopy.text("Category"), value: cause.category)
                        LabeledContent(appCopy.text("Phase"), value: cause.stage)
                        LabeledContent(appCopy.text("Error code"), value: cause.code)
                        ForEach(cause.details.keys.sorted(), id: \.self) { key in
                            LabeledContent(key, value: cause.details[key] ?? "").textSelection(.enabled)
                        }
                    }
                }
            }.font(.caption)
        }
    }

    @MainActor private struct WriterRequestImage: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        var recorded: Data? = nil
        @State private var data: Data?
        @State private var image: UIImage?
        @State private var failure: String?
        @State private var expanded = false
        var body: some View {
            Group {
                if let image {
                    Button {
                        expanded = true
                    } label: {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                    }
                } else if let failure {
                    Text(failure).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
            }.task {
                data = recorded
                if let data { image = await HistoryImageDecoder.decode(data, maximumPixelSize: 320) }
                if image == nil { failure = appCopy.text("Screenshot unavailable") }
            }.sheet(isPresented: $expanded) { if let data { HistoryImagePreview(data: data).background(.black) } }
        }
    }
    private struct WriterTextShare: UIViewControllerRepresentable {
        let text: String
        func makeUIViewController(context: Context) -> UIActivityViewController {
            .init(activityItems: [text], applicationActivities: nil)
        }
        func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    }
    @MainActor private struct WriterArtifactDetail: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        let item: WriterArtifactItem
        let controls: any WriterArtifactsControlling
        @State private var snapshot: WriterArtifactSnapshot?
        @State private var failure: String?
        @State private var busy = false
        @State private var operation: Task<Void, Never>?
        @State private var share: WriterShareFile?
        var body: some View {
            List {
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                if let snapshot {
                    Section {
                        Text(
                            snapshot.item.state == "published"
                                ? appCopy.text("Published project snapshot")
                                : appCopy.text("Draft snapshot · May contain unfinished work")
                        )
                        .foregroundStyle(.secondary)
                    }
                    Section(appCopy.text("Export current snapshot")) {
                        Button(appCopy.text("Export all source files (ZIP)")) {
                            export(snapshot, path: nil, pdf: false)
                        }
                        Button(appCopy.text("Export project PDF")) {
                            export(snapshot, path: snapshot.item.entry, pdf: true)
                        }
                        if busy { ProgressView(appCopy.text("Preparing export…")) }
                    }.disabled(busy)
                    Section(appCopy.text("Files")) {
                        ForEach(snapshot.files) { file in
                            NavigationLink(file.path) {
                                WriterFileView(snapshot: snapshot, file: file, controls: controls)
                                    .navigationTitle(file.path)
                            }
                        }
                    }
                }
            }.navigationTitle(item.title)
                .task {
                    do { snapshot = try await controls.read(item.id) } catch { failure = "Could not load: \(error)" }
                }
                .sheet(
                    item: $share,
                    onDismiss: {
                        operation = Task {
                            do { try await controls.discardExport() } catch {
                                failure = "Export cleanup failed: \(error)"
                            }
                        }
                    }
                ) { WriterActivitySheet(url: $0.url) }
                .onDisappear { operation?.cancel() }
        }
        private func export(_ snapshot: WriterArtifactSnapshot, path: String?, pdf: Bool) {
            guard !busy else { return }
            busy = true
            failure = nil
            operation = Task {
                defer { busy = false }
                do {
                    let url = try await controls.export(snapshot, path: path, pdf: pdf)
                    try Task.checkCancellation()
                    share = WriterShareFile(url: url)
                } catch is CancellationError {} catch { failure = "Export failed: \(error)" }
            }
        }
    }
    @MainActor private struct WriterFileView: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        let snapshot: WriterArtifactSnapshot
        let file: WriterArtifactFile
        let controls: any WriterArtifactsControlling
        @State private var preview: WriterFilePreview?
        @State private var page = WebPageContainer()
        @Environment(\.scenePhase) private var scenePhase
        @State private var failure: String?
        @State private var source = false
        @State private var busy = false
        @State private var operation: Task<Void, Never>?
        @State private var share: WriterShareFile?
        var body: some View {
            VStack {
                Toggle(appCopy.text("View source"), isOn: $source).padding(.horizontal)
                if let failure { Text(failure).foregroundStyle(.red) }
                if !source, preview != nil {
                    WebPageView(page: page)
                } else {
                    ScrollView {
                        Text(file.content).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding()
                    }
                }
            }.task {
                do {
                    let prepared = try await controls.preview(snapshot, path: file.path)
                    preview = prepared
                    page.setAvailable(scenePhase == .active)
                    _ = try await page.loadLocal(prepared.url, executesScripts: true, readAccessRoot: prepared.root)
                } catch {
                    failure = "Preview failed: \(error)"
                }
            }
            .toolbar {
                Button(appCopy.text("Export source file")) { export(pdf: false) }.disabled(busy)
                Button("PDF") { export(pdf: true) }.disabled(busy)
            }
            .sheet(
                item: $share,
                onDismiss: {
                    operation = Task {
                        do { try await controls.discardExport() } catch { failure = "Export cleanup failed: \(error)" }
                    }
                }
            ) { WriterActivitySheet(url: $0.url) }
            .onChange(of: scenePhase) { _, value in page.setAvailable(value == .active) }
            .onDisappear {
                page.close()
                operation?.cancel()
                page.close()
                Task { do { try await controls.closePreview() } catch { failure = "Preview cleanup failed: \(error)" } }
            }
        }
        private func export(pdf: Bool) {
            guard !busy else { return }
            busy = true
            failure = nil
            operation = Task {
                defer { busy = false }
                do {
                    let url = try await controls.export(snapshot, path: file.path, pdf: pdf)
                    try Task.checkCancellation()
                    share = WriterShareFile(url: url)
                } catch is CancellationError {} catch { failure = "Export failed: \(error)" }
            }
        }
    }
    private struct WriterShareFile: Identifiable {
        let id = UUID()
        let url: URL
    }
    private struct WriterActivitySheet: UIViewControllerRepresentable {
        let url: URL
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: [url], applicationActivities: nil)
        }
        func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    }
#endif

extension WriterRecordsControlling {
    public func clearRequestLogs(requestID: String?) async throws { throw HistoryDetailError.unavailable }
}
