import AgentCore
import Agents
import ModelKit
import Storage
import SwiftUI

/// Durable records of actual Assistant requests. Viewing never executes stored markup.
@MainActor
struct ConversationHistoryView: View {
    let loadHistory: () async throws -> ConversationHistoryStore
    let makeChat: () async throws -> any ChatCapability
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: ConversationHistoryStore?
    @State private var archive: ConversationArchive?
    @State private var status: String?
    @State private var task: Task<Void, Never>?
    @State private var deleting: StoredConversation?

    var body: some View {
        List {
            if let status { Section { Text(status).foregroundStyle(.secondary).textSelection(.enabled) } }
            Section {
                if let current = archive?.current {
                    if current.turns.isEmpty {
                        Text("尚无对话，返回首页开始聊天。").foregroundStyle(.secondary)
                    } else {
                        NavigationLink {
                            ConversationHistoryDetail(conversation: current)
                        } label: {
                            row(current)
                        }
                    }
                    Button("开始新对话", systemImage: "square.and.pencil") { startNew() }
                        .disabled(task != nil || current.turns.isEmpty)
                        .accessibilityIdentifier("history.new")
                } else if status == nil {
                    ProgressView("加载对话…")
                } else {
                    Button("重试加载") { Task { await reload() } }
                }
            } header: {
                Text("当前对话")
            } footer: {
                Text("继续聊天会加载当前会话最近 10 轮完整对话。关闭录音或重启应用不会清空上下文；开始新对话才会归档并清空。")
            }
            Section("过去的对话") {
                if archive?.past.isEmpty == true { Text("暂无历史对话").foregroundStyle(.secondary) }
                ForEach(archive?.past ?? []) { conversation in
                    NavigationLink {
                        ConversationHistoryDetail(conversation: conversation)
                    } label: {
                        row(conversation)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { deleting = conversation }
                    }
                    if conversation.summaryTitle == nil {
                        Button("重新生成标题") { summarize(conversation) }.disabled(task != nil)
                        if let error = conversation.titleError {
                            Text("标题生成失败：\(error)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Text(
                    "保存正式聊天的用户原文、实际请求上下文和模型文本分片。原始内容按纯文本显示，不执行历史 Action。失败、取消或中断时保留已接收部分；不包含模型未公开的推理、token ID 或 HTTP 数据。历史只保存在本机，容量用满后明确报错，可删除旧会话释放空间。"
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("对话历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await reload() }
        .refreshable { await reload() }
        .onDisappear { task?.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { task?.cancel() } }
        .alert(
            "删除这段历史对话？",
            isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let selected = deleting { delete(selected) }
                deleting = nil
            }
        } message: {
            Text("将删除该会话的用户输入、模型原文和请求记录，无法恢复。")
        }
    }

    private func row(_ conversation: StoredConversation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: conversation.title).lineLimit(2)
            Text(
                "\(conversation.turns.count) 轮 · \(conversation.createdAt.formatted(date: .abbreviated, time: .shortened))"
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func reload() async {
        do {
            let loaded = try await loadHistory()
            store = loaded
            archive = try await loaded.snapshot()
        } catch { status = "历史读取失败：\(error)" }
    }

    private func startNew() {
        guard task == nil, let store else { return }
        task = Task {
            defer { task = nil }
            do {
                guard let previous = try await store.startNew() else { return }
                archive = try await store.snapshot()
                status = "新对话已开始，正在为上一段对话生成标题…"
                await generateTitle(previous, store: store)
            } catch { status = "创建新对话失败：\(error)" }
        }
    }

    private func summarize(_ conversation: StoredConversation) {
        guard task == nil, let store else { return }
        task = Task {
            defer { task = nil }
            await generateTitle(conversation, store: store)
        }
    }

    private func generateTitle(_ conversation: StoredConversation, store: ConversationHistoryStore) async {
        do {
            let chat = try await makeChat()
            try Task.checkCancellation()
            let title = try await ConversationTitleGenerator.summarize(conversation, using: chat)
            try Task.checkCancellation()
            try await store.setTitle(title, for: conversation.id)
            status = "历史标题已保存。"
        } catch {
            do {
                try await store.setTitle(nil, error: String(describing: error), for: conversation.id)
                status = "会话已归档，标题尚未生成，可稍后重试。"
            } catch { status = "保存标题状态失败：\(error)" }
        }
        do { archive = try await store.snapshot() } catch { status = "刷新历史失败：\(error)" }
    }

    private func delete(_ conversation: StoredConversation) {
        guard task == nil, let store else { return }
        task = Task {
            defer { task = nil }
            do {
                try await store.deleteArchived(conversation.id)
                archive = try await store.snapshot()
            } catch { status = "删除失败：\(error)" }
        }
    }
}

@MainActor
private struct ConversationHistoryDetail: View {
    let conversation: StoredConversation
    var body: some View {
        List {
            ForEach(conversation.turns) { turn in
                NavigationLink {
                    ConversationTurnDetail(turn: turn)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: turn.user).lineLimit(3)
                        Text(verbatim: turn.raw.isEmpty ? "（无模型输出）" : turn.raw).lineLimit(3).foregroundStyle(.secondary)
                        Text("\(turn.date.formatted()) · \(turn.state.rawValue)").font(.caption)
                    }
                }
            }
        }
        .navigationTitle(String(conversation.title.prefix(40)))
        .toolbar { ShareLink("导出", item: export) }
    }
    private var export: String {
        conversation.turns.map { turn in
            "USER\n\(turn.user)\n\nASSISTANT RAW\n\(turn.raw)\n\nSTATE: \(turn.state.rawValue)\nERROR: \(turn.error ?? "none")"
        }.joined(separator: "\n\n---\n\n")
    }
}

@MainActor
private struct ConversationTurnDetail: View {
    let turn: ConversationRecord
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
                Text(
                    "max tokens: \(turn.maximumOutputTokens.map(String.init) ?? "模型默认") · temperature: \(turn.temperature)"
                )
                if let error = turn.error { selectable(error) }
                if let error = turn.executionError { selectable("执行失败：" + error) }
            }
            Section("实际发送的上下文（含系统提示词）") {
                ForEach(Array(turn.request.enumerated()), id: \.offset) { _, message in
                    DisclosureGroup(message.role.rawValue) { selectable(message.content) }
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
        .task { preview() }
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
            Maximum tokens: \(turn.maximumOutputTokens.map(String.init) ?? "模型默认"); temperature: \(turn.temperature)
            Generation error: \(turn.error ?? "none")
            Execution error: \(turn.executionError ?? "none")

            ACTUAL REQUEST
            \(messages)

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
    private func preview() {
        do {
            let configuration = try AgentConfigurations.load(named: "Assistant")
            var trace = try GenerationTrace(
                capabilities: AssistantAgent.runtimeCapabilities(configuration.capabilities),
                textMapping: AssistantAgent.mapText)
            for delta in turn.fragments { try trace.append(delta) }
            if turn.finishReason != nil { trace.finish() }
            var depth = 0
            let lines = trace.events.enumerated().map { index, event in
                if case .scheduling(.endWait) = event { depth = max(0, depth - 1) }
                let prefix = "\(index + 1). " + String(repeating: "  ", count: depth)
                switch event {
                case .scheduling(.beginWait):
                    depth += 1
                    return prefix + "<wait>"
                case .scheduling(.endWait): return prefix + "</wait>"
                case .action(let call): return prefix + "[\(call.channel)] \(call.actionPath) \(call.parameters)"
                }
            }
            interpretation = ([trace.parserError ?? "已接收内容的解析结果；不代表实际执行顺序。"] + lines).joined(separator: "\n")
        } catch { interpretation = "预览失败：\(error)" }
    }
}
