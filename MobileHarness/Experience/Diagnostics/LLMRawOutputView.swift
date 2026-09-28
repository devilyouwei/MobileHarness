import AgentCore
import Agents
import ModelKit
import SwiftUI

/// Explicit capability diagnostic; no Agent input, Action dispatch or device effects.
@MainActor
struct LLMRawOutputView: View {
    let modelName: String
    let makeChat: () async throws -> any ChatCapability
    @Environment(\.scenePhase) private var scenePhase
    @State private var prompt = "请先露出思考的表情，再用两句话介绍你自己。"
    @State private var maximumTokens = 256
    @State private var trace: GenerationTrace?
    @State private var systemPrompt = ""
    @State private var requestSummary = ""
    @State private var status = "尚未开始"
    @State private var finishReason: String?
    @State private var timedOut = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Text(modelName)
                Text("独立单轮测试，使用已保存的模型、正式 Assistant 提示词和 JSON 配置，无对话历史。只检查原文和解析结果，不执行 Channel 调度、语音或表情。")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("输入测试内容", text: $prompt, axis: .vertical)
                    .lineLimit(3...8)
                    .disabled(task != nil)
                    .accessibilityIdentifier("llm.raw.prompt")
                Stepper("最多 \(maximumTokens) tokens", value: $maximumTokens, in: 64...2048, step: 64)
                    .disabled(task != nil)
                Text("temperature = 0.7；默认 256 tokens 与正式对话相同。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("开始生成") { start() }
                        .disabled(task != nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("llm.raw.start")
                    Spacer()
                    Button("停止", role: .destructive) { task?.cancel() }
                        .disabled(task == nil)
                }
            } header: {
                Text("测试输入")
            }
            Section("生成状态") {
                Text(status).textSelection(.enabled)
                if let finishReason { Text("结束原因：\(finishReason)") }
                Text("\(trace?.raw.utf8.count ?? 0) UTF-8 字节 · \(trace?.fragments.count ?? 0) 个文本分片")
                if let trace, trace.raw.utf8.count > 2000 {
                    Text("已超过正式 Assistant 的 2000 字节限制；正式对话会在这里中止，本测试继续收集。")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                selectable(trace?.raw ?? "")
                    .accessibilityIdentifier("llm.raw.output")
                if let trace, !trace.raw.isEmpty {
                    ShareLink("导出原文", item: trace.raw)
                    ShareLink("导出诊断报告", item: report)
                }
            } header: {
                Text("完整原始文本")
            } footer: {
                Text(
                    "逐字拼接 ChatEvent.text，保留 XML、空格和换行，不做 Markdown 渲染。这是模型适配器交给 Agent 的文本，不含适配器未暴露的 tokenizer ID、隐藏推理或 HTTP 数据。取消、失败或超限时仅保留已收到的部分。"
                )
            }
            Section("解析结果 / Channel（未执行）") {
                Text(
                    trace?.parserError.map { "解析失败：\($0)；原文继续收集。" }
                        ?? (trace?.finished == true ? "解析完成" : "等待生成完成；下方为已解析部分")
                )
                .textSelection(.enabled)
                selectable(callReport)
                Text("按解析顺序列出；不同 Channel 的实际完成顺序可能不同。Speech.speak(text) 是合成 audioID 转换之前的结果。本页不验证执行调度。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("分片明细（转义显示换行和引号）") {
                    selectable(fragmentReport)
                }
                DisclosureGroup("实际请求与系统提示词") {
                    selectable(requestSummary + "\n\n" + systemPrompt)
                }
            }
        }
        .navigationTitle("LLM 原始输出测试")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onDisappear { task?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { task?.cancel() }
        }
    }

    private func selectable(_ text: String) -> some View {
        Text(verbatim: text.isEmpty ? "（空）" : text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var callReport: String {
        var depth = 0
        return (trace?.events ?? []).enumerated().map { index, event in
            if case .scheduling(.endWait) = event { depth = max(0, depth - 1) }
            let prefix = "\(index + 1). " + String(repeating: "  ", count: depth)
            switch event {
            case .scheduling(.beginWait):
                depth += 1
                return prefix + "<wait> 等待父组前序工作"
            case .scheduling(.endWait):
                return prefix + "</wait> 组内完成后放行后续工作"
            case .action(let call):
                let parameters = call.parameters.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\(String(reflecting: $0.value))" }.joined(separator: ", ")
                return prefix + "[\(call.channel)] \(call.actionPath)(\(parameters))"
            }
        }.joined(separator: "\n")
    }

    private var fragmentReport: String {
        (trace?.fragments ?? []).enumerated().map { index, delta in
            "\(index + 1). \(String(reflecting: delta))"
        }.joined(separator: "\n")
    }

    private var report: String {
        """
        LLM raw output diagnostic (dry run, no actions executed)
        \(requestSummary)
        Status: \(status)
        Finish: \(finishReason ?? "none")
        Parser: \(trace?.parserError ?? (trace?.finished == true ? "complete" : "partial"))
        Production 2000-byte limit exceeded: \((trace?.raw.utf8.count ?? 0) > 2000)

        SYSTEM PROMPT
        \(systemPrompt)

        RAW TEXT
        \(trace?.raw ?? "")

        RESOLVED ACTIONS (before speech audioID conversion)
        \(callReport)

        TEXT FRAGMENTS (escaped; not tokenizer tokens)
        \(fragmentReport)
        """
    }

    private func start() {
        guard task == nil else { return }
        trace = nil
        finishReason = nil
        timedOut = false
        systemPrompt = ""
        status = "正在准备模型…"
        let input = prompt
        let tokens = maximumTokens
        requestSummary =
            "Model: \(modelName)\nMaximum tokens: \(tokens); temperature: 0.7; history: none\nUser: \(input)"
        task = Task {
            defer { task = nil }
            do {
                guard input.utf8.count <= 4096 else {
                    throw CapabilityError.invalidRequest("测试输入不得超过 4096 UTF-8 字节")
                }
                let configuration = try AgentConfigurations.load(named: "Assistant")
                trace = try GenerationTrace(
                    capabilities: configuration.capabilities, textActions: configuration.textActions)
                systemPrompt = AssistantAgent.systemPrompt(capabilities: configuration.capabilities)
                let provider = try await makeChat()
                try Task.checkCancellation()
                let request = try ChatRequest(
                    messages: [.init(role: .system, content: systemPrompt), .init(role: .user, content: input)],
                    maximumOutputTokens: tokens, temperature: 0.7)
                requestSummary += "\nRequest: \(request.context.requestID)"
                let session = try await provider.chat(request)
                defer { session.cancel() }
                let deadline = Task {
                    do {
                        try await Task.sleep(for: .seconds(120))
                        timedOut = true
                        session.cancel()
                    } catch {}
                }
                defer { deadline.cancel() }
                status = "正在生成…"
                try await withTaskCancellationHandler {
                    for try await event in session.events {
                        try Task.checkCancellation()
                        guard finishReason == nil else {
                            throw CapabilityError.invalidRequest("完成事件之后仍收到输出")
                        }
                        switch event {
                        case .text(let delta): try trace?.append(delta)
                        case .finished(let reason):
                            finishReason = reason == .stop ? "stop（模型结束）" : "lengthLimit（达到 token 上限，可能不完整）"
                        }
                    }
                    try Task.checkCancellation()
                    guard finishReason != nil else {
                        throw CapabilityError.unavailable("流已结束，但没有完成事件；原文可能不完整")
                    }
                    trace?.finish()
                    status = trace?.raw.isEmpty == true ? "生成结束，模型未返回文本" : "生成结束（原文已完整收集）"
                } onCancel: {
                    session.cancel()
                }
            } catch {
                if timedOut {
                    status = "生成超过 120 秒，已停止；保留部分原文"
                } else if Task.isCancelled || error is CancellationError {
                    status = "已取消；保留部分原文"
                } else if let error = error as? GenerationError, error == .limitExceeded {
                    status = "达到诊断上限（256 KiB / 8192 分片），已停止；原文不完整"
                } else {
                    status = "生成失败；保留已收到的原文：\(error)"
                }
            }
        }
    }
}
