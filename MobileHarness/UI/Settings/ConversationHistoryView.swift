#if os(iOS)
    import SwiftUI
    import UIKit

    /// Agent selection followed by isolated durable request history.
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
                .navigationTitle("对话历史")
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
                    NavigationLink {
                        ConversationTurnDetail(turn: turn, controls: controls)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            if turn.isReACT == true { Text("ReACT").font(.caption).foregroundStyle(.orange) }
                            Text(turn.displayInput).lineLimit(3)
                            Text(turn.outputSummary).lineLimit(3).foregroundStyle(.secondary)
                            Text(turn.dateReport).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if turns.isEmpty && !state.isBusy { Text("暂无匹配的模型记录，关联输入可能已超出保留范围").foregroundStyle(.secondary) }
            }
            .navigationTitle("模型与 Tool 记录")
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
                                if current.turns.isEmpty {
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
                                        .disabled(state.isBusy || current.turns.isEmpty)
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
                            Text("对话历史仅保存在此设备。")
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
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: ConversationHistoryPresentation.title(conversation)).lineLimit(2)
                Text(
                    "\(ConversationHistoryPresentation.turns(conversation).count) 轮 · \(conversation.createdAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption).foregroundStyle(.secondary)
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
                    ForEach(state.tasks.filter(\.isAssociated)) { task in row(task) }
                    if state.tasks.isEmpty {
                        if state.isBusy {
                            ProgressView("加载任务…")
                        } else if state.status == nil {
                            Text("暂无任务记录").foregroundStyle(.secondary)
                        }
                    }
                }
                let unassociated = state.tasks.filter { !$0.isAssociated }
                if !unassociated.isEmpty {
                    Section("未关联任务的记录") {
                        ForEach(unassociated) { task in row(task) }
                    }
                }
            }
        }
        private func row(_ task: HistoryTask) -> some View {
            NavigationLink {
                ConversationHistoryDetail(task: task, controls: controls)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: task.title).lineLimit(2)
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
    private struct ConversationHistoryDetail: View {
        let turns: [HistoryTurn]
        let title: String
        let task: HistoryTask?
        let controls: any ConversationHistoryControlling
        init(conversation: HistoryConversation, controls: any ConversationHistoryControlling) {
            turns = ConversationHistoryPresentation.turns(conversation)
            title = ConversationHistoryPresentation.title(conversation)
            task = nil
            self.controls = controls
        }
        init(task: HistoryTask, controls: any ConversationHistoryControlling) {
            turns = task.turns
            title = task.title
            self.task = task
            self.controls = controls
        }
        var body: some View {
            List {
                if let task {
                    Section(task.isAssociated ? "任务信息" : "记录信息") {
                        Text(task.status)
                        Text(task.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "")
                        Text("\(task.isAssociated ? "任务 ID" : "输入 ID")：\(task.id)").font(.caption).textSelection(
                            .enabled)
                    }
                    if turns.isEmpty { Text("此任务暂无模型对话记录").foregroundStyle(.secondary) }
                }
                ForEach(turns) { turn in
                    NavigationLink {
                        ConversationTurnDetail(turn: turn, controls: controls)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if turn.isReACT == true {
                                Text("ReACT").font(.caption2.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.orange.opacity(0.15), in: Capsule())
                            }
                            Text(verbatim: turn.displayInput).lineLimit(3)
                            Text(verbatim: turn.outputSummary).lineLimit(3)
                                .foregroundStyle(turn.isReACT == true ? Color.orange : Color.secondary)
                            Text([turn.dateReport, turn.stateReport].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                        }
                    }
                    .listRowBackground(
                        turn.isReACT == true
                            ? Color.orange.opacity(0.08) : Color(uiColor: .secondarySystemGroupedBackground)
                    )
                    .foregroundStyle(turn.isReACT == true ? Color.orange : Color.primary)
                }
            }
            .navigationTitle(String(title.prefix(40)))
            .toolbar { ShareLink("导出", item: export) }
        }
        private var export: String {
            (task.map {
                "\($0.isAssociated ? "任务" : "记录")：\($0.title)\n\($0.isAssociated ? "任务 ID" : "输入 ID")：\($0.id)\n状态：\($0.status)\n\n"
            } ?? "")
                + turns.map { $0.diagnosticReport() }
                .joined(separator: "\n\n---\n\n")
        }
    }

    @MainActor
    private struct ConversationTurnDetail: View {
        let turn: HistoryTurn
        let controls: any ConversationHistoryControlling
        @State private var interpretation = ""
        @State private var generationInfoExpanded = false
        var body: some View {
            Form {
                Section("用户本轮输入") {
                    if turn.isReACT == true { Text("ReACT · 执行结果 / 观察输入").font(.caption).foregroundStyle(.orange) }
                    selectable(turn.displayInput)
                }
                Section("模型本轮输出") {
                    selectable(turn.raw)
                    if let calls = turn.toolCalls, !calls.isEmpty {
                        ForEach(calls) { call in
                            DisclosureGroup("Tool Call · \(call.name) · \(call.state.rawValue)") {
                                selectable("模型调用 ID：" + call.providerID)
                                selectable("执行调用 ID：" + call.id.uuidString)
                                Text("输入参数").font(.caption)
                                selectable(call.argumentsJSON)
                                Text("输出结果").font(.caption)
                                selectable(call.output ?? "")
                                if let error = call.error { selectable("失败原因：" + error) }
                            }
                        }
                    }
                }
                Section("实际发送的上下文（含系统提示词）") {
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
                            if let id = message.toolCallID { selectable("Tool Call ID：" + id) }
                            ForEach(Array((message.toolCalls ?? []).enumerated()), id: \.offset) { _, call in
                                selectable("Tool Call：\(call.name) · \(call.id)\n\(call.argumentsJSON)")
                            }
                        }
                    }
                }
                if let definitions = turn.toolDefinitions, !definitions.isEmpty {
                    Section("实际发送的 Tools") {
                        ForEach(Array(definitions.enumerated()), id: \.offset) { index, definition in
                            DisclosureGroup("Tool \(index + 1)") { selectable(definition) }
                        }
                    }
                }
                Section("解析预览（按当前协议，未执行）") { selectable(interpretation) }
                Section {
                    DisclosureGroup("原始分片（转义显示）") {
                        selectable(
                            turn.fragments.enumerated().map { "\($0.offset + 1). \(String(reflecting: $0.element))" }
                                .joined(separator: "\n"))
                    }
                }
                if turn.error != nil || turn.executionError != nil {
                    Section("异常信息") {
                        if let error = turn.error { selectable(error) }
                        if let error = turn.executionError { selectable("执行失败：" + error) }
                    }
                }
                Section {
                    DisclosureGroup("生成信息", isExpanded: $generationInfoExpanded) {
                        Text("轮次：\(turn.generationMetadataAvailable == false ? "" : turn.id.uuidString)")
                            .font(.caption).textSelection(.enabled)
                        Text("所属输入：\(turn.ownerInputID?.uuidString ?? "")")
                            .font(.caption).textSelection(.enabled)
                        Text("模型：\(turn.model)")
                        Text(turn.firstTokenReport)
                        Text("状态：\(turn.stateReport)；结束原因：\(turn.finishReason ?? "")")
                        Text("temperature: \(turn.temperature)")
                        Text(turn.tokenReport)
                    }
                }
            }
            .navigationTitle("对话详情")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink("导出", item: turn.diagnosticReport(interpretation: interpretation))
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
