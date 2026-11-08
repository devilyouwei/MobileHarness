import Foundation

#if os(iOS)
    import SwiftUI
    import UIKit

    /// Each Agent supplies its own record view and schema; no history workflow lives in the hub.
    @MainActor
    public struct AgentRecordDestination: Identifiable {
        public let id: String
        public let name: String
        public let summary: String
        private let content: () -> AnyView
        public init<Content: View>(
            id: String, name: String, summary: String, @ViewBuilder content: @escaping () -> Content
        ) {
            self.id = id
            self.name = name
            self.summary = summary
            self.content = { AnyView(content()) }
        }
        public func makeView() -> AnyView { content() }
    }

    @MainActor
    public struct ConversationHistoryView: View {
        @Bindable private var state: ConversationHistoryState
        private let controls: any ConversationHistoryControlling
        public init(state: ConversationHistoryState, controls: any ConversationHistoryControlling) {
            self.state = state
            self.controls = controls
        }
        public var body: some View { AgentConversationHistoryList(state: state, controls: controls) }
    }

    @MainActor
    private struct AgentConversationHistoryList: View {
        @Environment(\.recordContextID) private var recordContextID
        @Bindable var state: ConversationHistoryState
        let controls: any ConversationHistoryControlling
        @Environment(\.scenePhase) private var scenePhase
        @State private var deleting: HistoryConversation?
        @State private var clearingLogs = false
        @State private var initialLoad = HistoryInitialLoad()
        var body: some View {
            List {
                if let status = state.status {
                    Section { Text(status).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                Section {
                    if let current = state.archive?.current {
                        if (current.turnCount ?? current.turns.count) == 0 {
                            Text("No conversations yet.").foregroundStyle(.secondary)
                        } else {
                            NavigationLink {
                                ConversationHistoryDetail(conversation: current, controls: controls).id(current.id)
                            } label: {
                                row(current)
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        }

                        Button("New Conversation", systemImage: "square.and.pencil") { controls.startNew() }
                            .disabled(state.isBusy || (current.turnCount ?? current.turns.count) == 0)
                            .accessibilityIdentifier("history.new")
                    } else if state.status == nil {
                        ProgressView("Loading conversations…")
                    } else {
                        Button("Retry") { Task { await reload() } }
                    }
                } header: {
                    Text("Current Conversation")
                } footer: {
                    Text("Starting a new conversation archives the current one.")
                }
                Section {
                    if state.archive?.past.isEmpty == true {
                        Text("No past conversations.").foregroundStyle(.secondary)
                    }
                    ForEach(state.archive?.past ?? []) { conversation in
                        NavigationLink {
                            ConversationHistoryDetail(conversation: conversation, controls: controls).id(
                                conversation.id)
                        } label: {
                            row(conversation)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .swipeActions {
                            Button("Delete", role: .destructive) { deleting = conversation }
                        }
                        if conversation.summaryTitle == nil {
                            Button("Regenerate Title") { controls.summarize(conversation.id) }.disabled(state.isBusy)
                            if let error = conversation.titleError {
                                Text("Title generation failed: \(error)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if state.hasMoreArchives, let cursor = state.archive?.past.last?.id {
                        HistoryPagingFooter(
                            cursor: cursor, state: state.archivePaging,
                            enabled: !state.isRefreshing && (!state.isBusy || state.archivePaging.isLoading)
                        ) { retry in await controls.loadMoreArchives(retry: retry) }
                    }
                } header: {
                    Text("Past Conversations")
                } footer: {
                    Text("History is stored only on this device.")
                }
            }
            .navigationContext(
                .agentRecords, itemID: recordContextID,
                content: state.archive == nil ? state.status == nil ? .loading : .failed : .ready,
                overlay: deleting != nil ? .deleteConfirmation : nil
            )
            .navigationTitle(state.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空请求日志", systemImage: "trash") { clearingLogs = true }
                }
            }
            .confirmationDialog("清空整个请求日志库？", isPresented: $clearingLogs, titleVisibility: .visible) {
                Button("清空全部日志", role: .destructive) {
                    Task {
                        do { try await controls.clearRequestLogs(requestID: nil) } catch {
                            state.present(.status("日志清空失败：\(error)"))
                        }
                    }
                }
            } message: {
                Text("删除 Assistant 和 Writer 的全部请求日志；保留对话、消息及其他详情。")
            }
            .task {
                guard initialLoad.begin() else { return }
                await reload()
            }
            .refreshable { await reload() }
            .onDisappear { controls.cancel() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { controls.cancel() } }
            .alert(
                "Delete this conversation?",
                isPresented: Binding(
                    get: { deleting != nil }, set: { if !$0 { deleting = nil } })
            ) {
                Button("Cancel", role: .cancel) { deleting = nil }
                Button("Delete", role: .destructive) {
                    if let selected = deleting { controls.delete(selected.id) }
                    deleting = nil
                }
            } message: {
                Text("This cannot be undone.")
            }
        }

        private func reload() async {
            await controls.load()
            initialLoad.finish(succeeded: !Task.isCancelled && state.archive != nil && state.status == nil)
        }

        private func row(_ conversation: HistoryConversation) -> some View {
            HistoryRecordRow(
                title: ConversationHistoryPresentation.title(conversation), icon: "text.bubble", tint: .blue
            ) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("\(conversation.turnCount ?? conversation.turns.count) turns").fixedSize()
                        Spacer(minLength: 8)
                        conversationDate(conversation)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(conversation.turnCount ?? conversation.turns.count) turns")
                        conversationDate(conversation).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        private func conversationDate(_ conversation: HistoryConversation) -> some View {
            Text(HistoryListPresentation.date(conversation.createdAt))
                .fixedSize()
                .accessibilityLabel(
                    "Started " + conversation.createdAt.formatted(date: .complete, time: .shortened))
        }

    }

    struct HistoryRecordRow<Metadata: View>: View {
        let title: String
        let icon: String
        let tint: Color
        let metadata: Metadata
        init(title: String, icon: String, tint: Color, @ViewBuilder metadata: () -> Metadata) {
            self.title = title
            self.icon = icon
            self.tint = tint
            self.metadata = metadata()
        }
        var body: some View {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    metadata.font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 36 }
        }
    }

    private struct HistoryPagingTrigger<Cursor: Hashable & Sendable>: Hashable, Sendable {
        let cursor: Cursor
        let retryID: UUID
        let completionID: UUID?
        let enabled: Bool
    }

    @MainActor
    private struct HistoryPagingFooter<Cursor: Hashable & Sendable>: View {
        let cursor: Cursor
        let state: HistoryPageLoading<Cursor>
        var enabled = true
        let load: @MainActor (Bool) async -> Void
        @State private var retryID = UUID()
        @State private var retryRequested = false
        var body: some View {
            VStack(spacing: 8) {
                if let error = state.error {
                    Text(error).font(.footnote).textSelection(.enabled)
                    Button("重试") {
                        retryRequested = true
                        retryID = UUID()
                    }
                    .disabled(!enabled || state.isLoading)
                } else {
                    ProgressView().accessibilityLabel("正在加载更多记录")
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
            .task(
                id: HistoryPagingTrigger(
                    cursor: cursor, retryID: retryID, completionID: state.completionID, enabled: enabled)
            ) {
                guard enabled, !Task.isCancelled else { return }
                let retry = retryRequested
                retryRequested = false
                await load(retry)
            }
        }
    }

    @MainActor
    private struct ConversationHistoryDetail: View {
        private let seed: HistoryConversation
        @State private var loaded: HistoryConversation?
        @State private var initialLoad = HistoryInitialLoad()
        @State private var loadError: String?
        @State private var isRefreshing = false
        @State private var expandedTasks: Set<String> = []
        @State private var taskPages: [String: HistoryConversation] = [:]
        @Environment(\.scenePhase) private var scenePhase
        @State private var messageLoader = HistoryMessageLoader()
        @State private var items: [HistoryTimelineItem] = []
        @State private var pageLoading = HistoryPageLoading<UInt64>()
        @State private var taskLoading: [String: HistoryPageLoading<UInt64>] = [:]
        @State private var pageWorker: Task<Void, Never>?
        @State private var taskWorkers: [String: Task<Void, Never>] = [:]
        @State private var requestNavigation = HistoryRequestNavigation()
        let title: String
        let controls: any ConversationHistoryControlling
        init(conversation: HistoryConversation, controls: any ConversationHistoryControlling) {
            seed = conversation
            title = ConversationHistoryPresentation.title(conversation)
            self.controls = controls
        }
        var body: some View {
            List {
                if let error = loadError ?? messageLoader.error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("重试") { Task { await reload() } }.disabled(isRefreshing)
                    }
                }
                Section {
                    ForEach(items) { item in
                        switch item {
                        case .request(let turn):
                            requestRow(turn)
                        case .task(let compression, let sources):
                            Group {
                                taskSummary(compression, sourceCount: compression.sources.count)
                                if expandedTasks.contains(compression.taskID) {
                                    let visible =
                                        taskPages[compression.taskID].map(ConversationHistoryPresentation.turns)
                                        ?? sources
                                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, turn in
                                        requestRow(turn, showsIcon: false, endsTask: index == visible.count - 1)
                                    }
                                    if taskPages[compression.taskID] == nil
                                        || taskPages[compression.taskID]?.nextPosition != nil
                                    {
                                        let cursor = taskPages[compression.taskID]?.nextPosition ?? 0
                                        HistoryPagingFooter(
                                            cursor: cursor, state: taskLoading[compression.taskID] ?? .init(),
                                            enabled: !isRefreshing
                                        ) { retry in await loadTask(compression.taskID, after: cursor, retry: retry) }
                                        .listRowInsets(EdgeInsets(top: 8, leading: 52, bottom: 8, trailing: 20))
                                    }
                                }
                            }
                        }
                    }
                    if let next = loaded?.nextPosition {
                        HistoryPagingFooter(cursor: next, state: pageLoading, enabled: !isRefreshing) { retry in
                            await loadPage(after: next, retry: retry)
                        }
                    }
                }
                .listSectionSeparator(.hidden)
            }
            .task(id: seed.id) {
                guard loaded == nil, initialLoad.begin() else { return }
                do { items = try await ConversationHistoryPresentation.timelineOffMain(seed) } catch {
                    initialLoad.finish(succeeded: false)
                    return
                }
                await reload()
                initialLoad.finish(succeeded: !Task.isCancelled && loaded != nil)
            }
            .refreshable { await reload() }
            .overlay {
                if loaded == nil && loadError == nil { ProgressView("加载对话…") }
            }
            .onDisappear { messageLoader.cancel() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { messageLoader.cancel() } }
            .navigationContext(
                .conversation, itemID: seed.id,
                content: loadError != nil ? .failed : loaded == nil || isRefreshing ? .loading : .ready
            )
            .navigationTitle(String(title.prefix(40)))
            .navigationDestination(isPresented: $requestNavigation.isPresented) {
                if let turn = requestNavigation.turn { ConversationTurnDetail(turn: turn, controls: controls) }
            }
            .toolbar {
                if let loaded {
                    HistoryJSONShareButton(value: loaded, filename: "\(loaded.id).json")
                }
            }
        }
        private func taskSummary(_ compression: HistoryTaskCompression, sourceCount: Int) -> some View {
            let expanded = expandedTasks.contains(compression.taskID)
            return Button {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if !expandedTasks.insert(compression.taskID).inserted {
                        expandedTasks.remove(compression.taskID)
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checklist").foregroundStyle(.blue).frame(width: 24)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: compression.goal).font(.headline).foregroundStyle(.blue)
                        HStack(spacing: 6) {
                            Text("\(compression.status.rawValue) · \(sourceCount) 轮对话")
                                .font(.caption).foregroundStyle(.secondary)
                            typeBadge("Task", color: .blue)
                        }
                        if !compression.text.isEmpty {
                            Text(verbatim: compression.text).font(.subheadline).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityIdentifier("history.compression.\(compression.taskID)")
            .accessibilityValue(expanded ? "已展开" : "已收起")
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 20))
            .modifier(HistoryTimelineRowSeparator(leading: expanded && sourceCount > 0 ? 36 : -16))
        }
        private func requestRow(_ turn: HistoryTurn, showsIcon: Bool = true, endsTask: Bool = false) -> some View {
            Button {
                guard !requestNavigation.isPresented else { return }
                messageLoader.open(read: { try await controls.loadMessage(turn) }) { requestNavigation.open($0) }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    if showsIcon {
                        Image(systemName: turn.isReACT == true ? "arrow.clockwise" : "text.bubble")
                            .foregroundStyle(turn.isReACT == true ? Color.orange : Color.secondary).frame(width: 24)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: turn.displayInput).lineLimit(2)
                            .foregroundStyle(turn.isReACT == true ? Color.orange : Color.primary)
                        Text(verbatim: turn.outputSummary).font(.subheadline).lineLimit(2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text([turn.dateReport, turn.stateReport].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if turn.isReACT == true {
                                typeBadge("ReACT", color: .orange)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("history.request.\(turn.id)")
            .listRowInsets(EdgeInsets(top: 12, leading: showsIcon ? 16 : 52, bottom: 12, trailing: 20))
            .modifier(HistoryTimelineRowSeparator(leading: showsIcon ? -16 : (endsTask ? -52 : 0)))
            .foregroundStyle(.primary)
        }

        private func reload() async {
            guard !isRefreshing, !Task.isCancelled else { return }
            isRefreshing = true
            messageLoader.cancel()
            defer { isRefreshing = false }
            let readers = Array(taskWorkers.values) + [pageWorker].compactMap { $0 }
            for reader in readers { reader.cancel() }
            for reader in readers { await reader.value }
            // Joined readers cannot append into the refreshed generation or exceed its read bound.
            pageLoading = .init()
            taskLoading.removeAll()
            do {
                try Task.checkCancellation()
                let conversation = try await controls.loadConversation(seed.id)
                let timeline = try await ConversationHistoryPresentation.timelineOffMain(conversation)
                try Task.checkCancellation()
                loaded = conversation
                items = timeline
                taskPages.removeAll()
                loadError = nil
                initialLoad.finish(succeeded: true)
            } catch {
                if !Task.isCancelled { loadError = "读取失败：\(error)" }
            }
        }
        private func loadPage(after: UInt64, retry: Bool) async {
            guard !isRefreshing, !Task.isCancelled, loaded?.nextPosition == after,
                let ticket = pageLoading.begin(after: after, retry: retry)
            else {
                return
            }
            let worker = Task {
                defer { pageWorker = nil }
                await readPage(after: after, ticket: ticket)
            }
            pageWorker = worker
            await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
        private func readPage(after: UInt64, ticket: UUID) async {
            do {
                try Task.checkCancellation()
                let page = try await controls.loadConversation(seed.id, after: after, taskID: nil)
                try Task.checkCancellation()
                guard pageLoading.accepts(ticket) else { return }
                guard page.nextPosition.map({ $0 > after }) ?? true else { throw HistoryDetailError.unavailable }
                guard var conversation = loaded else { throw HistoryDetailError.unavailable }
                try conversation.appendPage(page)
                let timeline = try await ConversationHistoryPresentation.timelineOffMain(conversation)
                try Task.checkCancellation()
                guard pageLoading.accepts(ticket) else { return }
                loaded = conversation
                items = timeline
                pageLoading.finish(ticket)
            } catch is CancellationError {
                pageLoading.cancel(ticket)
            } catch {
                if Task.isCancelled {
                    pageLoading.cancel(ticket)
                } else {
                    pageLoading.finish(ticket, error: "读取失败：\(error)")
                }
            }
        }
        private func loadTask(_ id: String, after: UInt64, retry: Bool) async {
            guard !isRefreshing, !Task.isCancelled, expandedTasks.contains(id) else { return }
            if let page = taskPages[id] {
                guard page.nextPosition == after else { return }
            } else if after != 0 {
                return
            }
            let active = taskLoading.values.filter(\.isLoading).count
            guard let ticket = taskLoading[id, default: .init()].begin(after: after, retry: retry) else { return }
            guard active < 16 else {
                taskLoading[id]?.finish(ticket, error: "同时加载的任务过多，请重试。")
                return
            }
            let worker = Task {
                defer { taskWorkers[id] = nil }
                await readTask(id, after: after, ticket: ticket)
            }
            taskWorkers[id] = worker
            await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
        private func readTask(_ id: String, after: UInt64, ticket: UUID) async {
            do {
                try Task.checkCancellation()
                let page = try await controls.loadConversation(seed.id, after: after, taskID: id)
                try Task.checkCancellation()
                guard taskLoading[id]?.accepts(ticket) == true else { return }
                guard page.nextPosition.map({ $0 > after }) ?? true else { throw HistoryDetailError.unavailable }
                if var existing = taskPages[id] {
                    try existing.appendPage(page)
                    taskPages[id] = existing
                } else {
                    guard page.id == seed.id else { throw HistoryDetailError.unavailable }
                    taskPages[id] = page
                }
                taskLoading[id]?.finish(ticket)
            } catch is CancellationError {
                taskLoading[id]?.cancel(ticket)
            } catch {
                if Task.isCancelled {
                    taskLoading[id]?.cancel(ticket)
                } else {
                    taskLoading[id]?.finish(ticket, error: "读取失败：\(error)")
                }
            }
        }
        private func typeBadge(_ title: String, color: Color) -> some View {
            Text(verbatim: title).font(.caption2.bold())
                .foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color.opacity(0.15), in: Capsule())
        }

    }

    private struct HistoryJSONDocument<Value: Encodable & Sendable>: Transferable {
        let value: Value
        let filename: String
        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(exportedContentType: .json) { document in
                try Task.checkCancellation()
                let data = try ConversationHistoryPresentation.jsonData(document.value)
                try Task.checkCancellation()
                return data
            }
            .suggestedFileName { $0.filename }
        }
    }

    private struct HistoryJSONShareButton<Value: Encodable & Sendable>: View {
        let value: Value
        let filename: String
        var body: some View {
            ShareLink(
                "导出", item: HistoryJSONDocument(value: value, filename: filename),
                preview: SharePreview(filename))
        }
    }

    private struct HistoryTimelineRowSeparator: ViewModifier {
        let leading: CGFloat
        func body(content: Content) -> some View {
            content
                .alignmentGuide(.listRowSeparatorLeading) { _ in leading }
                .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width + 20 }
                .listRowSeparator(.hidden, edges: .top)
                .listRowSeparator(.visible, edges: .bottom)
        }
    }

    @MainActor
    private struct ConversationTurnDetail: View {
        @State private var turn: HistoryTurn
        let controls: any ConversationHistoryControlling
        @State private var clearingLog = false
        @State private var clearFailure: String?
        @State private var catalog: HistoryFunctionCatalog?
        @State private var catalogError: String?
        @State private var catalogSource: String?
        @State private var isClearingLog = false
        @State private var catalogExpanded = false
        @State private var catalogRawExpanded = false

        init(turn: HistoryTurn, controls: any ConversationHistoryControlling) {
            self._turn = State(initialValue: turn)
            self.controls = controls
        }

        var body: some View {
            Form {
                Section("User Request") {
                    if turn.isReACT == true {
                        Text("ReACT · Execution observations").font(.caption).foregroundStyle(.orange)
                    }
                    selectable(turn.displayInput)
                }
                Section("Assistant Response") {
                    if !turn.raw.isEmpty || (turn.toolCalls ?? []).isEmpty { selectable(turn.raw) }
                    ForEach(turn.toolCalls ?? []) { call in selectable(call.responseReport) }
                }
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Tasks", systemImage: "checklist").foregroundStyle(.blue)
                            .font(.subheadline.weight(.semibold))
                        taskInformation
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Skills", systemImage: "square.stack.3d.up").foregroundStyle(.purple)
                            .font(.subheadline.weight(.semibold))
                        skillsInformation
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Label("States", systemImage: "square.stack.3d.down.right").foregroundStyle(.orange)
                            .font(.subheadline.weight(.semibold))
                        statesInformation
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Function Catalog", systemImage: "function").foregroundStyle(.green)
                            .font(.subheadline.weight(.semibold))
                        if turn.decisionMetadata != nil {
                            functionCatalog
                        } else {
                            Text("Not recorded").foregroundStyle(.secondary)
                        }
                    }
                }.accessibilityIdentifier("history.business.context")
                if turn.logsCleared == true {
                    Section {
                        Text("Logs cleared").foregroundStyle(.secondary)
                            .accessibilityIdentifier("history.prompts.cleared")
                    }
                } else {
                    Section("Prompts") {
                        if !turn.attachedImages.isEmpty {
                            ScrollView(.horizontal) {
                                HStack(spacing: 12) {
                                    ForEach(turn.attachedImages) { reference in
                                        HistoryImageThumbnail(reference: reference, turnID: turn.id, controls: controls)
                                    }
                                }
                            }
                        }
                        if turn.request.isEmpty {
                            Text("Prompt messages unavailable").foregroundStyle(.secondary)
                        }
                        HistoryPromptItems(messages: turn.request)
                        if !turn.effectiveToolDefinitions.isEmpty {
                            DisclosureGroup("Functions") {
                                ForEach(Array(turn.effectiveToolDefinitions.enumerated()), id: \.offset) {
                                    index, definition in
                                    DisclosureGroup("Tool \(index + 1)") { selectable(definition) }
                                }
                            }
                        }
                    }
                    Section("Generation Meta") {
                        if let error = turn.error { selectable("Generation Error: " + error) }
                        Text("Request ID: \(turn.id)").font(.caption).textSelection(.enabled)
                        Text("Input ID: \(turn.ownerInputID ?? "")").font(.caption).textSelection(.enabled)
                        Text("Model: \(turn.model)")
                        Text(turn.firstTokenReport)
                        Text("State: \(turn.stateReport); Finish Reason: \(turn.finishReason ?? "")")
                        Text("Temperature: \(turn.temperature)")
                        Text(turn.tokenReport)
                    }
                    Section {
                        if let clearFailure { Text(clearFailure).foregroundStyle(.red) }
                        Button("清空此条请求日志", role: .destructive) { clearingLog = true }
                            .disabled(isClearingLog || turn.messageID?.hasPrefix("request_") != true)
                        if isClearingLog { ProgressView() }
                    }
                }
            }
            .navigationContext(.turn, itemID: turn.id)
            .navigationTitle("对话详情")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HistoryJSONShareButton(value: turn, filename: "\(turn.id).json")
                }
            }
            .confirmationDialog("清空此条请求日志？", isPresented: $clearingLog, titleVisibility: .visible) {
                Button("清空日志", role: .destructive) {
                    Task {
                        guard !isClearingLog else { return }
                        isClearingLog = true
                        clearFailure = nil
                        defer { isClearingLog = false }
                        do {
                            guard let id = turn.messageID else { throw HistoryDetailError.unavailable }
                            try await controls.clearRequestLogs(requestID: id)
                            turn = ConversationHistoryPresentation.clearingLogs(turn)
                        } catch { clearFailure = "日志清空失败：\(error)" }
                    }
                }
            } message: {
                Text("完整请求及日志内图片将被删除；其他详情保留。")
            }
            .task(id: turn.decisionMetadata?.catalogJSON) {
                guard let source = turn.decisionMetadata?.catalogJSON, source != catalogSource else { return }
                catalog = nil
                catalogError = nil
                do {
                    let result = try await ConversationHistoryPresentation.functionCatalogOffMain(source)
                    try Task.checkCancellation()
                    catalog = result
                    catalogSource = source
                } catch {
                    guard !Task.isCancelled else { return }
                    catalogError = error.localizedDescription
                    catalogSource = source
                }
            }
        }

        private var taskInformation: some View {
            VStack(alignment: .leading, spacing: 10) {
                if turn.decisionMetadata == nil && turn.historyTaskID == nil {
                    Text("Not recorded").foregroundStyle(.secondary)
                }
                if let metadata = turn.decisionMetadata {
                    Text(
                        metadata.execution.map { $0 == "foreground" ? "Foreground task" : "Background task" }
                            ?? "Default conversation at request"
                    ).font(.caption).foregroundStyle(.secondary)
                    if let goal = metadata.taskGoal, !goal.isEmpty {
                        Text(verbatim: goal).font(.subheadline).textSelection(.enabled)
                    }
                }
                ForEach(ConversationHistoryPresentation.taskReferences(for: turn)) { reference in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            reference.isHistoryOwner
                                ? (reference.wasActiveAtRequest ? "Task ID · Active at request" : "Task ID")
                                : "Active task ID at request"
                        ).font(.caption).foregroundStyle(.secondary)
                        selectable(reference.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        @ViewBuilder private var functionCatalog: some View {
            HistoryCatalogToggle(isExpanded: $catalogExpanded) {
                HStack {
                    Text("Actions and Tools")
                    Spacer()
                    if let catalog {
                        Text("\(catalog.actions.count) Actions · \(catalog.tools.count) Tools")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if catalogExpanded {
                if let catalog {
                    catalogGroup("Actions", entries: catalog.actions, color: .blue)
                    catalogGroup("Tools", entries: catalog.tools, color: .purple)
                } else if let catalogError {
                    Text("Unable to read Function Catalog").foregroundStyle(.orange)
                    selectable(catalogError)
                    HistoryCatalogToggle(isExpanded: $catalogRawExpanded) { Text("Raw JSON") }
                    if catalogRawExpanded {
                        selectable(turn.decisionMetadata?.catalogJSON ?? "")
                    }
                }
            }
        }

        @ViewBuilder private func catalogGroup(
            _ title: String, entries: [HistoryFunctionRegistration], color: Color
        ) -> some View {
            Text("\(title) · \(entries.count)").font(.subheadline.weight(.semibold)).foregroundStyle(color)
            ForEach(Array(entries.sorted { ($0.alias, $0.path) < ($1.alias, $1.path) }.enumerated()), id: \.offset) {
                _, entry in
                HistoryCatalogEntryRow(entry: entry)
            }
        }

        @ViewBuilder private var skillsInformation: some View {
            if let metadata = turn.decisionMetadata {
                if metadata.skills.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    HistorySkillFlowLayout(spacing: 8) {
                        ForEach(metadata.skills.keys.sorted(), id: \.self) { id in
                            Text("\(id) · v\(metadata.skills[id] ?? 0)")
                                .font(.caption).textSelection(.enabled)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.purple.opacity(0.12), in: Capsule())
                        }
                    }
                }
            } else {
                Text("Not recorded").foregroundStyle(.secondary)
            }
        }

        @ViewBuilder private var statesInformation: some View {
            if let states = turn.decisionMetadata?.states {
                if states.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    HistorySkillFlowLayout(spacing: 8) {
                        ForEach(states, id: \.self) { path in
                            Text(verbatim: path)
                                .font(.caption).textSelection(.enabled)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.orange.opacity(0.12), in: Capsule())
                        }
                    }
                }
            } else {
                Text("Not recorded").foregroundStyle(.secondary)
            }
        }

        private func selectable(_ text: String) -> some View {
            Text(verbatim: text)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    /// Each toggle is a separate Form row; no ancestor row contains child buttons.
    private struct HistoryCatalogToggle<Label: View>: View {
        @Binding var isExpanded: Bool
        @ViewBuilder var label: () -> Label

        var body: some View {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    label()
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        }
    }

    struct HistoryCatalogEntryRow: View {
        let entry: HistoryFunctionRegistration
        @State private var isExpanded = false
        @State private var definitionExpanded = false

        var body: some View {
            Group {
                HistoryCatalogToggle(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: entry.alias).font(.system(.subheadline, design: .monospaced))
                        Text(verbatim: entry.path).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 16)
                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        if let channel = entry.channel { Text(verbatim: "Channel: " + channel) }
                        if !entry.required.isEmpty {
                            Text(verbatim: "Required: " + entry.required.sorted().joined(separator: ", "))
                        }
                        if !entry.optional.isEmpty {
                            Text(verbatim: "Optional: " + entry.optional.sorted().joined(separator: ", "))
                        }
                        if entry.required.isEmpty && entry.optional.isEmpty {
                            Text("No parameters").foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .padding(.leading, 32)
                    if let definition = entry.definitionJSON, !definition.isEmpty {
                        HistoryCatalogToggle(isExpanded: $definitionExpanded) { Text("Definition") }
                            .padding(.leading, 32)
                        if definitionExpanded {
                            Text(verbatim: definition).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).padding(.leading, 48)
                        }
                    }
                }
            }
        }
    }

    private struct HistorySkillFlowLayout: Layout {
        let spacing: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let idealWidth = subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
            let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? max(0, idealWidth - spacing)
            return arrangement(subviews, width: width).size
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let result = arrangement(subviews, width: bounds.width)
            for (index, subview) in subviews.enumerated() {
                subview.place(
                    at: CGPoint(x: bounds.minX + result.origins[index].x, y: bounds.minY + result.origins[index].y),
                    anchor: .topLeading, proposal: ProposedViewSize(result.sizes[index]))
            }
        }

        private func arrangement(_ subviews: Subviews, width: CGFloat)
            -> (origins: [CGPoint], sizes: [CGSize], size: CGSize)
        {
            let availableWidth = max(0, width)
            var origins: [CGPoint] = []
            var sizes: [CGSize] = []
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            for subview in subviews {
                let size = subview.sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
                if x > 0, x + size.width > availableWidth {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                origins.append(CGPoint(x: x, y: y))
                sizes.append(size)
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            return (origins, sizes, CGSize(width: availableWidth, height: y + rowHeight))
        }
    }

    @MainActor
    private struct HistoryImageThumbnail: View {
        let reference: HistoryImageReference
        let turnID: String
        let controls: any ConversationHistoryControlling
        @State private var data: Data?
        @State private var thumbnail: UIImage?
        @State private var failed = false
        @State private var expired = false
        @State private var loading = true
        @State private var retry = 0
        @State private var inspecting = false

        var body: some View {
            ZStack {
                if let thumbnail {
                    Button {
                        inspecting = true
                    } label: {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                            .frame(width: 112, height: 84).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看记录中的图片")
                    .accessibilityIdentifier("history.image.\(reference.id)")
                } else if loading {
                    ProgressView().frame(width: 112, height: 84)
                } else if expired {
                    Label("图片已释放", systemImage: "photo")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 112, height: 84)
                } else if failed {
                    Button("重试图片", systemImage: "arrow.clockwise") { retry += 1 }
                        .frame(width: 112, height: 84)
                }
            }
            .frame(width: 112, height: 84)
            .task(id: "\(turnID):\(reference.id):\(retry)") {
                loading = true
                failed = false
                expired = false
                do {
                    let bytes = try await controls.imageData(reference.id, for: turnID)
                    try Task.checkCancellation()
                    guard let bytes,
                        let image = await HistoryImageDecoder.decode(bytes, maximumPixelSize: 320)
                    else { throw HistoryImageDecodeError.invalidImage }
                    try Task.checkCancellation()
                    data = bytes
                    thumbnail = image
                } catch HistoryImageAvailabilityError.expired {
                    guard !Task.isCancelled else { return }
                    expired = true
                } catch {
                    guard !Task.isCancelled else { return }
                    failed = true
                }
                loading = false
            }
            .retainedFullScreenCover(isPresented: $inspecting) {
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()
                    if let data { HistoryImagePreview(data: data) }
                    Button("关闭", systemImage: "xmark") { inspecting = false }
                        .padding().foregroundStyle(.white)
                        .background(.black.opacity(0.65), in: Capsule()).padding()
                }
            }
        }

    }

    @MainActor
    struct HistoryImagePreview: View {
        let data: Data
        @State private var image: UIImage?
        @State private var failed = false
        @State private var retry = 0
        var body: some View {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if failed {
                    VStack {
                        Text("图片无法打开")
                        Button("重试", systemImage: "arrow.clockwise") { retry += 1 }
                    }.foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: retry) {
                failed = false
                let prepared = await HistoryImageDecoder.decode(data, maximumPixelSize: 2048)
                guard !Task.isCancelled else { return }
                image = prepared
                failed = prepared == nil
            }
        }
    }

    @MainActor
    enum HistoryImageDecoder {
        static func decode(_ data: Data, maximumPixelSize: Int) async -> UIImage? {
            guard !Task.isCancelled, data.count <= 4 * 1024 * 1024, let image = UIImage(data: data) else { return nil }
            let longestSide = max(image.size.width, image.size.height)
            guard longestSide > 0 else { return nil }
            let scale = min(1, CGFloat(maximumPixelSize) / longestSide)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            return await image.byPreparingThumbnail(ofSize: size)
        }
    }
    private enum HistoryImageDecodeError: Error { case invalidImage }

    /// Protocol message rows shared by Assistant and Writer record details.
    struct HistoryPromptItems: View {
        let messages: [HistoryMessage]
        var body: some View {
            ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                DisclosureGroup(message.role.rawValue) {
                    selectable(message.displayContent)
                    if let id = message.toolCallID { selectable("Tool Call ID: " + id) }
                    ForEach(Array((message.toolCalls ?? []).enumerated()), id: \.offset) { _, call in
                        selectable("Tool Call: \(call.name) · \(call.id)\n\(call.argumentsJSON)")
                    }
                }
            }
        }
        private func selectable(_ text: String) -> some View {
            Text(verbatim: text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }
#endif
