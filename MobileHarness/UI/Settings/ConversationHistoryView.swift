#if os(iOS)
    import SwiftUI
    import UIKit

    /// Assistant chat and task history destinations.
    @MainActor
    public struct ConversationHistoryView: View {
        @Bindable var state: ConversationHistoryState
        let controls: any ConversationHistoryControlling
        public init(state: ConversationHistoryState, controls: any ConversationHistoryControlling) {
            self.state = state
            self.controls = controls
        }

        public var body: some View {
            if controls.agents.isEmpty {
                AgentConversationHistoryList(state: state, controls: controls)
            } else {
                List(controls.agents) { agent in
                    NavigationLink {
                        AgentConversationHistoryList(state: agent.state, controls: agent.controls)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(agent.name)
                            Text(agent.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("history.agent.\(agent.id)")
                }
                .navigationTitle("历史记录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
            }
        }
    }

    /// Task-scoped read-only projection using the owning Agent's existing history and controls.
    @MainActor
    public struct TaskConversationHistoryView: View {
        @Bindable private var state: ConversationHistoryState
        private let controls: any ConversationHistoryControlling
        private let inputIDs: Set<UUID>
        @State private var requestNavigation = HistoryRequestNavigation()
        public init(state: ConversationHistoryState, controls: any ConversationHistoryControlling, inputIDs: Set<UUID>)
        {
            self.state = state
            self.controls = controls
            self.inputIDs = inputIDs
        }
        private var turns: [HistoryTurn] {
            guard let archive = state.archive else { return [] }
            return ([archive.current] + archive.past).flatMap {
                ConversationHistoryPresentation.turns($0, inputIDs: inputIDs)
            }
        }
        public var body: some View {
            List {
                if let status = state.status { Text(status).foregroundStyle(.secondary) }
                ForEach(turns) { turn in
                    Button {
                        requestNavigation.open(turn)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("对话", systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary)
                            if turn.isReACT == true { Text("ReACT").font(.caption).foregroundStyle(.orange) }
                            if let metadata = turn.decisionMetadata {
                                Text(metadata.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text(turn.displayInput).lineLimit(3)
                            Text(turn.outputSummary).lineLimit(3).foregroundStyle(.secondary)
                            Text(turn.dateReport).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if turns.isEmpty && !state.isBusy { Text("暂无匹配的模型记录，关联输入可能已超出保留范围").foregroundStyle(.secondary) }
            }
            .navigationTitle("模型与 Tool 记录")
            .navigationDestination(isPresented: $requestNavigation.isPresented) {
                if let turn = requestNavigation.turn { ConversationTurnDetail(turn: turn, controls: controls) }
            }
            .task { await controls.load() }
        }
    }

    @MainActor
    private struct AgentConversationHistoryList: View {
        @Bindable var state: ConversationHistoryState
        let controls: any ConversationHistoryControlling
        @Environment(\.scenePhase) private var scenePhase
        @State private var deleting: HistoryConversation?
        var body: some View {
            Group {
                if state.groupsByTask {
                    SpecialistTaskHistoryList(state: state, controls: controls)
                } else {
                    List {
                        if let status = state.status {
                            Section { Text(status).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        Section {
                            if let current = state.archive?.current {
                                if (current.turnCount ?? current.turns.count) == 0 {
                                    Text("此 Agent 尚无对话记录。").foregroundStyle(.secondary)
                                } else {
                                    NavigationLink {
                                        ConversationHistoryDetail(conversation: current, controls: controls)
                                    } label: {
                                        row(current)
                                    }
                                }
                                if state.allowsMutations {
                                    Button("开始新对话", systemImage: "square.and.pencil") { controls.startNew() }
                                        .disabled(state.isBusy || (current.turnCount ?? current.turns.count) == 0)
                                        .accessibilityIdentifier("history.new")
                                }
                            } else if state.status == nil {
                                ProgressView("加载对话…")
                            } else {
                                Button("重试加载") { Task { await controls.load() } }
                            }
                        } header: {
                            Text("当前对话")
                        } footer: {
                            Text(state.allowsMutations ? "开始新对话后，当前对话会移至历史记录。" : "此 Agent 的记录可查看和导出。")
                        }
                        Section {
                            if state.archive?.past.isEmpty == true { Text("暂无历史对话").foregroundStyle(.secondary) }
                            ForEach(state.archive?.past ?? []) { conversation in
                                NavigationLink {
                                    ConversationHistoryDetail(conversation: conversation, controls: controls)
                                } label: {
                                    row(conversation)
                                }
                                .swipeActions {
                                    if state.allowsMutations {
                                        Button("删除", role: .destructive) { deleting = conversation }
                                    }
                                }
                                if state.allowsMutations, conversation.summaryTitle == nil {
                                    Button("重新生成标题") { controls.summarize(conversation.id) }.disabled(state.isBusy)
                                    if let error = conversation.titleError {
                                        Text("标题生成失败：\(error)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text("过去的对话")
                        } footer: {
                            Text("历史记录仅保存在此设备。")
                        }
                    }
                }
            }
            .navigationTitle(state.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task { await controls.load() }
            .refreshable { await controls.load() }
            .onDisappear { controls.cancel() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { controls.cancel() } }
            .alert(
                "删除这段历史对话？",
                isPresented: Binding(
                    get: { deleting != nil }, set: { if !$0 { deleting = nil } })
            ) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除", role: .destructive) {
                    if let selected = deleting { controls.delete(selected.id) }
                    deleting = nil
                }
            } message: {
                Text("删除后无法恢复。")
            }
        }

        private func row(_ conversation: HistoryConversation) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "text.bubble").foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: ConversationHistoryPresentation.title(conversation)).lineLimit(2)
                    Text(
                        "\(conversation.turnCount ?? conversation.turns.count) 轮 · \(conversation.createdAt.formatted(date: .abbreviated, time: .shortened))"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }

    }

    @MainActor
    private struct SpecialistTaskHistoryList: View {
        @Bindable var state: ConversationHistoryState
        let controls: any ConversationHistoryControlling
        var body: some View {
            List {
                if let status = state.status {
                    Section {
                        Text(status).foregroundStyle(.secondary)
                        Button("重试加载") { Task { await controls.load() } }
                    }
                }
                Section("任务") {
                    ForEach(state.tasks) { task in row(task) }
                    if state.tasks.isEmpty {
                        if state.isBusy {
                            ProgressView("加载任务…")
                        } else if state.status == nil {
                            Text("暂无任务记录").foregroundStyle(.secondary)
                        }
                    }
                }
                Section("历史任务按会话") {
                    ForEach(state.archive?.past ?? []) { conversation in
                        NavigationLink {
                            ArchivedTaskHistoryList(conversation: conversation, controls: controls)
                        } label: {
                            Text(ConversationHistoryPresentation.title(conversation))
                        }
                    }
                }

            }
        }
        private func row(_ task: HistoryTask) -> some View {
            NavigationLink {
                ConversationHistoryDetail(task: task, controls: controls)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Label(task.title, systemImage: "checklist").foregroundStyle(.blue).lineLimit(2)
                    if let execution = task.execution {
                        Text((execution == "background" ? "后台任务" : "前台任务") + " · " + (task.executor ?? "assistant"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !task.skills.isEmpty {
                        Text("Skills: " + task.skills.joined(separator: ", ")).font(.caption).foregroundStyle(
                            .secondary)
                    }
                    Text(
                        [
                            task.status, "\(task.turns.count) 轮",
                            task.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "",
                        ]
                        .filter { !$0.isEmpty }.joined(separator: " · ")
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("history.task.\(task.id)")
        }
    }

    @MainActor
    private struct ArchivedTaskHistoryList: View {
        let conversation: HistoryConversation
        let controls: any ConversationHistoryControlling
        @State private var loaded: HistoryConversation?
        @State private var failure: String?
        var body: some View {
            List {
                if let failure { Text(failure) }
                if let loaded {
                    ForEach(loaded.taskCompressions) { compression in
                        let turns = ConversationHistoryPresentation.turns(loaded).filter {
                            $0.historyTaskID == compression.taskID
                        }
                        let task = makeTask(compression, turns: turns)
                        NavigationLink {
                            ConversationHistoryDetail(task: task, controls: controls)
                        } label: {
                            VStack(alignment: .leading) {
                                Label(compression.goal, systemImage: "checklist").foregroundStyle(.blue)
                                Text(compression.status.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if loaded.taskCompressions.isEmpty { Text("此会话暂无任务记录") }
                } else if failure == nil {
                    ProgressView("加载任务…")
                }
            }
            .navigationTitle("历史任务")
            .task(id: conversation.id) {
                do { loaded = try await controls.loadConversation(conversation.id) } catch {
                    failure = "任务读取失败：\(error)"
                }
            }
        }
        private func makeTask(_ compression: HistoryTaskCompression, turns: [HistoryTurn]) -> HistoryTask {
            var task = HistoryTask(
                id: compression.taskID, title: compression.goal, status: compression.status.rawValue,
                createdAt: turns.first?.date, turns: turns)
            task.compression = compression
            task.resultText = compression.text
            task.execution = "foreground"
            task.executor = "assistant"
            return task
        }
    }

    @MainActor
    private struct ConversationHistoryDetail: View {
        private let seed: HistoryConversation?
        @State private var loaded: HistoryConversation?
        @State private var loadError: String?
        @State private var expandedTasks: Set<UUID> = []
        @State private var requestNavigation = HistoryRequestNavigation()
        private var turns: [HistoryTurn] {
            if let conversation = loaded ?? seed { return ConversationHistoryPresentation.turns(conversation) }
            return task?.turns ?? []
        }
        private var items: [HistoryTimelineItem] {
            if let conversation = loaded ?? seed { return ConversationHistoryPresentation.timeline(conversation) }
            return task?.compression.map { [.task($0, sources: turns)] } ?? turns.map { .request($0) }
        }
        let title: String
        let task: HistoryTask?
        let controls: any ConversationHistoryControlling
        init(conversation: HistoryConversation, controls: any ConversationHistoryControlling) {
            seed = conversation
            title = ConversationHistoryPresentation.title(conversation)
            task = nil
            self.controls = controls
        }
        init(task: HistoryTask, controls: any ConversationHistoryControlling) {
            seed = nil
            title = task.title
            self.task = task
            self.controls = controls
        }
        var body: some View {
            List {
                if let task {
                    Section("任务信息") {
                        Text("目标：" + task.title)
                        Text(task.status)
                        if let execution = task.execution {
                            Text((execution == "background" ? "后台任务" : "前台任务") + " · " + (task.executor ?? "assistant"))
                        }
                        if !task.skills.isEmpty { Text("Skills: " + task.skills.joined(separator: ", ")) }
                        if let parent = task.parentTaskID {
                            Text("父任务：" + parent.uuidString).font(.caption).textSelection(.enabled)
                        }
                        if let result = task.resultText { Text("结果 / 进度：" + result).textSelection(.enabled) }
                        Text(task.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "")
                        Text("任务 ID：\(task.id)").font(.caption).textSelection(
                            .enabled)
                    }
                    if turns.isEmpty { Text("此任务暂无模型对话记录").foregroundStyle(.secondary) }
                }
                Section {
                    ForEach(items) { item in
                        switch item {
                        case .request(let turn):
                            requestRow(turn)
                        case .task(let compression, let sources):
                            Group {
                                taskSummary(compression)
                                Button {
                                    var transaction = Transaction(animation: nil)
                                    transaction.disablesAnimations = true
                                    withTransaction(transaction) {
                                        if !expandedTasks.insert(compression.taskID).inserted {
                                            expandedTasks.remove(compression.taskID)
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(
                                            "\(expandedTasks.contains(compression.taskID) ? "收起" : "展开")任务内对话（\(sources.count) 轮）"
                                        )
                                        .font(.subheadline)
                                        Spacer()
                                        Image(
                                            systemName: expandedTasks.contains(compression.taskID)
                                                ? "chevron.up" : "chevron.down"
                                        )
                                        .font(.caption.weight(.semibold))
                                    }
                                    .foregroundStyle(.secondary).padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("history.expand.\(compression.taskID)")
                                .accessibilityValue(expandedTasks.contains(compression.taskID) ? "已展开" : "已收起")
                                .listRowInsets(EdgeInsets(top: 8, leading: 52, bottom: 8, trailing: 20))
                                .modifier(
                                    HistoryTimelineRowSeparator(
                                        leading: expandedTasks.contains(compression.taskID) && !sources.isEmpty
                                            ? 0 : -52))
                                if expandedTasks.contains(compression.taskID) {
                                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, turn in
                                        requestRow(turn, showsIcon: false, endsTask: index == sources.count - 1)
                                    }
                                }
                            }
                        }
                    }
                }
                .listSectionSeparator(.hidden)
            }
            .task(id: seed?.id) {
                guard let seed else { return }
                do {
                    let conversation = try await controls.loadConversation(seed.id)
                    try Task.checkCancellation()
                    loaded = conversation
                    loadError = nil
                } catch {
                    if !Task.isCancelled { loadError = "读取失败：\(error)" }
                }
            }
            .overlay {
                if let loadError { Text(loadError) } else if seed != nil && loaded == nil { ProgressView("加载对话…") }
            }
            .navigationTitle(String(title.prefix(40)))
            .navigationDestination(isPresented: $requestNavigation.isPresented) {
                if let turn = requestNavigation.turn { ConversationTurnDetail(turn: turn, controls: controls) }
            }
            .toolbar {
                if let task {
                    HistoryJSONShareButton(value: task, filename: "task-\(task.id).json")
                } else if let loaded {
                    HistoryJSONShareButton(value: loaded, filename: "conversation-\(loaded.id).json")
                }
            }
        }
        private func taskSummary(_ compression: HistoryTaskCompression) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checklist").foregroundStyle(.blue).frame(width: 24)
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: compression.goal).font(.headline).foregroundStyle(.blue)
                    Text(compression.status.rawValue).font(.caption).foregroundStyle(.secondary)
                    if !compression.text.isEmpty {
                        Text(verbatim: compression.text).font(.subheadline).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .accessibilityIdentifier("history.compression.\(compression.taskID)")
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 20))
            .modifier(HistoryTimelineRowSeparator(leading: 36))
        }
        private func requestRow(_ turn: HistoryTurn, showsIcon: Bool = true, endsTask: Bool = false) -> some View {
            Button {
                requestNavigation.open(turn)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    if showsIcon {
                        Image(systemName: "text.bubble")
                            .foregroundStyle(turn.isReACT == true ? Color.orange : Color.secondary).frame(width: 24)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: turn.displayInput).lineLimit(2)
                            .foregroundStyle(turn.isReACT == true ? Color.orange : Color.primary)
                        Text(verbatim: turn.outputSummary).font(.subheadline).lineLimit(2)
                            .foregroundStyle(turn.isReACT == true ? Color.orange : Color.secondary)
                        HStack(spacing: 6) {
                            Text([turn.dateReport, turn.stateReport].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if turn.isReACT == true {
                                Text("ReACT").font(.caption2.bold())
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.orange.opacity(0.15), in: Capsule())
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
        let turn: HistoryTurn
        let controls: any ConversationHistoryControlling
        @State private var interpretation = ""
        var body: some View {
            Form {
                Section("User Request") {
                    if turn.isReACT == true {
                        Text("ReACT · Execution observations").font(.caption).foregroundStyle(.orange)
                    }
                    selectable(turn.displayInput)
                }
                Section("Assistant Response") { selectable(turn.raw) }
                if turn.historyTaskID != nil || turn.decisionMetadata != nil {
                    Section("Tasks and Skills") {
                        if let id = turn.historyTaskID { selectable("History Task: " + id.uuidString) }
                        if let metadata = turn.decisionMetadata {
                            if let execution = metadata.execution {
                                Text(execution == "foreground" ? "Foreground task" : "Background task")
                                if let goal = metadata.taskGoal { selectable("Goal: " + goal) }
                            } else {
                                Text("Default conversation")
                            }
                            if let id = metadata.taskID { selectable("Active Task: " + id.uuidString) }
                            ForEach(metadata.skills.keys.sorted(), id: \.self) { id in
                                Text("\(id) · v\(metadata.skills[id] ?? 0)")
                            }
                            DisclosureGroup("Function Catalog") { selectable(metadata.catalogJSON) }
                        }
                    }
                }
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
                    if turn.request.isEmpty, let json = turn.requestJSON { selectable(json) }
                    ForEach(Array(turn.request.enumerated()), id: \.offset) { _, message in
                        DisclosureGroup(message.role.rawValue) {
                            selectable(message.displayContent)
                            if let id = message.toolCallID { selectable("Tool Call ID: " + id) }
                            ForEach(Array((message.toolCalls ?? []).enumerated()), id: \.offset) { _, call in
                                selectable("Tool Call: \(call.name) · \(call.id)\n\(call.argumentsJSON)")
                            }
                        }
                    }
                    if !turn.effectiveToolDefinitions.isEmpty {
                        DisclosureGroup("Functions") {
                            ForEach(Array(turn.effectiveToolDefinitions.enumerated()), id: \.offset) {
                                index, definition in
                                DisclosureGroup("Tool \(index + 1)") { selectable(definition) }
                            }
                        }
                    }
                }
                Section("Action Execution") {
                    if let calls = turn.toolCalls {
                        ForEach(calls) { call in
                            DisclosureGroup("Tool Call · \(call.name) · \(call.state.rawValue)") {
                                selectable("Provider Call ID: " + call.providerID)
                                selectable("Execution Call ID: " + call.id.uuidString)
                                Text("Arguments").font(.caption)
                                selectable(call.argumentsJSON)
                                Text("Result").font(.caption)
                                selectable(call.output ?? "")
                                if let error = call.error { selectable("Error: " + error) }
                            }
                        }
                    }
                    selectable(interpretation)
                    if let error = turn.executionError { selectable("Execution Error: " + error) }
                }
                Section("Generation Meta") {
                    if let error = turn.error { selectable("Generation Error: " + error) }
                    Text("Request ID: \(turn.id.uuidString)").font(.caption).textSelection(.enabled)
                    Text("Input ID: \(turn.ownerInputID?.uuidString ?? "")").font(.caption).textSelection(.enabled)
                    Text("Model: \(turn.model)")
                    Text(turn.firstTokenReport)
                    Text("State: \(turn.stateReport); Finish Reason: \(turn.finishReason ?? "")")
                    Text("Temperature: \(turn.temperature)")
                    Text(turn.tokenReport)
                }
            }
            .navigationTitle("对话详情")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HistoryJSONShareButton(value: turn, filename: "request-\(turn.id).json")
                }
            }
            .task { interpretation = controls.preview(turn) }
        }
        private func selectable(_ text: String) -> some View {
            Text(verbatim: text)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    @MainActor
    private struct HistoryImageThumbnail: View {
        let reference: HistoryImageReference
        let turnID: UUID
        let controls: any ConversationHistoryControlling
        @State private var data: Data?
        @State private var thumbnail: UIImage?
        @State private var failed = false
        @State private var loading = true
        @State private var retry = 0
        @State private var inspecting = false

        var body: some View {
            Group {
                if let thumbnail {
                    Button {
                        inspecting = true
                    } label: {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                            .frame(width: 112, height: 84).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看发送给模型的图片")
                    .accessibilityIdentifier("history.image.\(reference.id.uuidString)")
                } else if loading {
                    ProgressView().frame(width: 112, height: 84)
                } else if failed {
                    Button("重试图片", systemImage: "arrow.clockwise") { retry += 1 }
                        .frame(width: 112, height: 84)
                }
            }
            .task(id: retry) {
                loading = true
                failed = false
                do {
                    let bytes = try await controls.imageData(reference.id, for: turnID)
                    try Task.checkCancellation()
                    if let bytes {
                        guard let image = await HistoryImageDecoder.decode(bytes, maximumPixelSize: 320) else {
                            throw HistoryImageDecodeError.invalidImage
                        }
                        try Task.checkCancellation()
                        data = bytes
                        thumbnail = image
                    }
                } catch {
                    if !Task.isCancelled { failed = true }
                }
                loading = false
            }
            .fullScreenCover(isPresented: $inspecting) {
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
    private struct HistoryImagePreview: View {
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
    private enum HistoryImageDecoder {
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

#endif
