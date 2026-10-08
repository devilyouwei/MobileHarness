#if os(iOS)
    import SwiftUI

    /// Durable records of actual Assistant requests. Viewing never executes stored markup.
    @MainActor
    public struct ConversationHistoryView: View {
        @Bindable var state: ConversationHistoryState
        let controls: any ConversationHistoryControlling
        @Environment(\.scenePhase) private var scenePhase
        @State private var deleting: HistoryConversation?
        public init(state: ConversationHistoryState, controls: any ConversationHistoryControlling) {
            self.state = state
            self.controls = controls
        }

        public var body: some View {
            List {
                if let status = state.status {
                    Section { Text(status).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                Section {
                    if let current = state.archive?.current {
                        if current.turns.isEmpty {
                            Text("尚无对话，返回首页开始聊天。").foregroundStyle(.secondary)
                        } else {
                            NavigationLink {
                                ConversationHistoryDetail(conversation: current, controls: controls)
                            } label: {
                                row(current)
                            }
                        }
                        Button("开始新对话", systemImage: "square.and.pencil") { controls.startNew() }
                            .disabled(state.isBusy || current.turns.isEmpty)
                            .accessibilityIdentifier("history.new")
                    } else if state.status == nil {
                        ProgressView("加载对话…")
                    } else {
                        Button("重试加载") { Task { await controls.load() } }
                    }
                } header: {
                    Text("当前对话")
                } footer: {
                    Text("开始新对话后，当前对话会移至历史记录。")
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
                            Button("删除", role: .destructive) { deleting = conversation }
                        }
                        if conversation.summaryTitle == nil {
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
            .navigationTitle("对话历史")
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
                    "\(conversation.turns.count) 轮 · \(conversation.createdAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }

    }

    @MainActor
    private struct ConversationHistoryDetail: View {
        let conversation: HistoryConversation
        let controls: any ConversationHistoryControlling
        var body: some View {
            List {
                ForEach(conversation.turns) { turn in
                    NavigationLink {
                        ConversationTurnDetail(turn: turn, controls: controls)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: turn.user).lineLimit(3)
                            Text(verbatim: turn.outputSummary).lineLimit(3).foregroundStyle(.secondary)
                            Text("\(turn.date.formatted()) · \(turn.state.rawValue)").font(.caption)
                        }
                    }
                }
            }
            .navigationTitle(String(ConversationHistoryPresentation.title(conversation).prefix(40)))
            .toolbar { ShareLink("导出", item: export) }
        }
        private var export: String {
            conversation.turns.map { turn in
                "USER\n\(turn.user)\n\nASSISTANT RAW\n\(turn.raw)\n\nTOOLS\n\(turn.toolReport)\n\nTOKENS: \(turn.tokenReport)\nSTATE: \(turn.state.rawValue)\nERROR: \(turn.error ?? "none")"
            }.joined(separator: "\n\n---\n\n")
        }
    }

    @MainActor
    private struct ConversationTurnDetail: View {
        let turn: HistoryTurn
        let controls: any ConversationHistoryControlling
        @State private var interpretation = ""
        var body: some View {
            Form {
                Section("用户原始输入") { selectable(turn.user) }
                Section("模型原始输出") {
                    selectable(turn.raw)
                    ShareLink("导出原文", item: turn.raw)
                }
                Section("生成记录") {
                    Text("请求：\(turn.id.uuidString)").font(.caption).textSelection(.enabled)
                    Text("模型：\(turn.model)")
                    Text("状态：\(turn.state.rawValue)；结束原因：\(turn.finishReason ?? "未收到")")
                    Text("\(turn.raw.utf8.count) 字节 · \(turn.fragments.count) 分片")
                    Text("temperature: \(turn.temperature)")
                    Text(turn.tokenReport)
                    if let error = turn.error { selectable(error) }
                    if let error = turn.executionError { selectable("执行失败：" + error) }
                }
                if let calls = turn.toolCalls, !calls.isEmpty {
                    Section("Tool Call 输入 / 输出") {
                        ForEach(calls) { call in
                            DisclosureGroup("\(call.name) · \(call.state.rawValue)") {
                                selectable("模型调用 ID：" + call.providerID)
                                selectable("执行调用 ID：" + call.id.uuidString)
                                Text("输入参数").font(.caption)
                                selectable(call.argumentsJSON)
                                Text("输出结果").font(.caption)
                                selectable(
                                    call.output
                                        ?? (call.state == .completed
                                            ? "执行完成，无返回数据" : "未收到执行结果"))
                                if let error = call.error { selectable("失败原因：" + error) }
                            }
                        }
                    }
                    if let definitions = turn.toolDefinitions, !definitions.isEmpty {
                        Section("实际发送的 Tool 声明") {
                            ForEach(Array(definitions.enumerated()), id: \.offset) { index, definition in
                                DisclosureGroup("Tool \(index + 1)") { selectable(definition) }
                            }
                        }
                    }
                }
                Section("实际发送的上下文（含系统提示词）") {
                    ForEach(Array(turn.request.enumerated()), id: \.offset) { _, message in
                        DisclosureGroup(message.role.rawValue) { selectable(message.content) }
                    }
                }
                if let requests = turn.continuationRequests, !requests.isEmpty {
                    Section("实际发送的后续请求") {
                        ForEach(Array(requests.enumerated()), id: \.offset) { index, request in
                            DisclosureGroup("后续请求 \(index + 1)") { selectable(request) }
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
            }
            .navigationTitle("对话详情")
            .toolbar { ShareLink("导出诊断记录", item: report) }
            .task { interpretation = controls.preview(turn) }
        }
        private var report: String {
            let messages = turn.request.map { "[\($0.role.rawValue)]\n\($0.content)" }.joined(separator: "\n\n")
            let fragments = turn.fragments.enumerated().map {
                "\($0.offset + 1). \(String(reflecting: $0.element))"
            }.joined(separator: "\n")
            return """
                Request: \(turn.id)
                Model: \(turn.model)
                Date: \(turn.date)
                State: \(turn.state.rawValue); finish: \(turn.finishReason ?? "none")
                Temperature: \(turn.temperature)
                Tokens: \(turn.tokenReport)
                Generation error: \(turn.error ?? "none")
                Execution error: \(turn.executionError ?? "none")

                ACTUAL REQUEST
                \(messages)

                ACTUAL TOOL DEFINITIONS
                \((turn.toolDefinitions ?? []).joined(separator: "\n\n"))

                TOOL CALL INPUT / OUTPUT
                \(turn.toolReport)

                RAW MODEL TEXT
                \(turn.raw)

                RECEIVED FRAGMENTS (escaped)
                \(fragments)

                CURRENT PARSER PREVIEW (not execution evidence)
                \(interpretation)
                """
        }

        private func selectable(_ text: String) -> some View {
            Text(verbatim: text.isEmpty ? "（空）" : text)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    extension HistoryTurn {
        fileprivate var outputSummary: String {
            if !raw.isEmpty { return raw }
            guard let calls = toolCalls, !calls.isEmpty else { return "（无模型输出）" }
            return "Tool Call：" + calls.map(\.name).joined(separator: "、")
        }
        fileprivate var tokenReport: String {
            guard let usage = tokenUsage else { return "Token 用量：未提供" }
            return "输入：\(usage.input) tokens · 生成：\(usage.generated) tokens · 总计：\(usage.total) tokens"
        }
        fileprivate var toolReport: String {
            guard let calls = toolCalls else { return "未保存 Tool Call 数据" }
            if calls.isEmpty { return "本轮无 Tool Call" }
            return calls.map { call in
                """
                Name: \(call.name)
                Provider ID: \(call.providerID); runtime ID: \(call.id)
                State: \(call.state.rawValue)
                Input: \(call.argumentsJSON)
                Output: \(call.output ?? (call.state == .completed ? "Completed without return data" : "No execution result received"))
                Error: \(call.error ?? "none")
                """
            }.joined(separator: "\n\n")
        }
    }

#endif
