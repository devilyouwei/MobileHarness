import SwiftUI
import Foundation
import AgentCore
import Agents
import ModelKit
import ModelKitQwen35

@main struct Qwen35ProbeApp: App {
    @State private var status = "Testing Qwen3.5 on this iPhone…"
    var body: some Scene { WindowGroup { Text(status).padding().task {
        UIApplication.shared.isIdleTimerDisabled = true
        do { try await evaluate(); status = "Evaluation complete" }
        catch { status = "Evaluation failed: \(error)"; print("PROBE_FATAL \(error)") }
        UIApplication.shared.isIdleTimerDisabled = false
    } } }
}
actor Reply {
    var text = ""
    var first: Double?
    let start = Date()
    func append(_ delta: String) { if first == nil { first = Date().timeIntervalSince(start) }; text += delta }
}
func evaluate() async throws {
    let recorder = PromptRecorder()
    let agent = try AssistantAgent(chat: recorder)
    try await agent.start()
    try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("hello")))
    for await output in agent.outputs {
        if output.output == .control("assistant.finished") { break }
    }
    await agent.stop()
    let actualSystem = await recorder.system


    let configuration = try AgentConfigurations.load(named: "Assistant")
    let scenarios: [(String, [ChatMessage])] = [
        ("greeting", [.init(role: .user, content: "你好，你能陪我聊聊天吗？")]),
        ("arithmetic", [.init(role: .user, content: "我有3个苹果，又买了2个，吃掉1个，还剩几个？")]),
        ("everyday", [.init(role: .user, content: "家里只有鸡蛋、西红柿和米饭，晚饭做什么方便？请给我一个简单做法。")]),
        ("empathy", [.init(role: .user, content: "今天工作很累，感觉什么都没做好，有点失落。")]),
        (
            "recall",
            [
                .init(role: .user, content: "测试用的盒子叫蓝盒。"), .init(role: .assistant, content: "好的，测试盒叫蓝盒。"),
                .init(role: .user, content: "刚才说的测试盒叫什么？"),
            ]
        ),
        (
            "correction",
            [
                .init(role: .user, content: "我喜欢喝咖啡。"), .init(role: .assistant, content: "记住了，你喜欢咖啡。"),
                .init(role: .user, content: "不对，我刚才说错了，我喜欢喝茶。现在我喜欢喝什么？"),
            ]
        ),
        ("explicit_expression", [.init(role: .user, content: "请调用开心表情，再说一句祝贺我通过考试的话。")]),
        ("expression_only", [.init(role: .user, content: "只调用思考表情，不要输出其他文字。")]),
        ("channel", [.init(role: .user, content: "请在main channel内先调用微笑表情express，再调用惊讶表情express，然后在channel外说你好。")]),
        ("format", [.init(role: .user, content: "只输出这句话的英文翻译，不要解释：我明天去图书馆。")]),
    ]

    let root = Bundle.main.bundleURL.appendingPathComponent("Models/Qwen35")
    let profiles: [Qwen35Chat.Size] = [.twoB, .fourB]
    let installed = profiles.filter {
        FileManager.default.fileExists(atPath: root.appendingPathComponent($0.artifactID + ".manifest.json").path)
    }
    guard installed.count == 1, let size = installed.first else {
        throw CapabilityError.invalidRequest("Evaluation bundle must contain exactly one Qwen model profile")
    }
    let model = size == .fourB ? "Qwen35-4B" : "Qwen35-2B"
    let provider = Qwen35Chat(artifacts: root, manifest: root.appendingPathComponent(size.artifactID + ".manifest.json"), size: size)
    let loadStart = Date()
    try await provider.load()
    print("PROBE_LOADED \(model) \(Date().timeIntervalSince(loadStart))")
    let output = URL.documentsDirectory.appendingPathComponent(model + "-results.json")
    var results: [[String: Any]] = []
    for repetition in 0...2 {
        for (name, conversation) in scenarios {
            let messages = [ChatMessage(role: .system, content: actualSystem)] + conversation
            let reply = Reply()
            let start = Date()
            let session = try await provider.chat(ChatRequest(messages: messages, maximumOutputTokens: 256, temperature: repetition == 0 ? 0 : 0.7))
            var stopped = false
            for try await event in session.events {
                switch event {
                case .text(let delta): await reply.append(delta)
                case .finished(let reason): stopped = reason == .stop
                }
            }
            let answer = await reply.text
            let elapsed = Date().timeIntervalSince(start)
            var protocolError = ""
            var actions: [String] = []
            do {
                var generator = try AgentGenerator(capabilities: configuration.capabilities, textActions: configuration.textActions)
                let calls = try generator.append(answer) + generator.finish()
                actions = calls.map { "\($0.actionPath.module).\($0.actionPath.function)@\($0.channel):\($0.parameters)" }
                for call in calls where call.actionPath.function == "express" {
                    if !["smile", "happy", "laugh", "thinking", "surprised", "sad", "love"].contains(call.parameters["emotion"] ?? "") { protocolError = "Unsupported emotion" }
                }
            } catch { protocolError = String(describing: error) }
            let result: [String: Any] = ["model": model, "scenario": name, "repetition": repetition, "temperature": repetition == 0 ? 0.0 : 0.7, "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }, "answer": answer, "stopped": stopped, "firstTextSeconds": await reply.first ?? -1, "totalSeconds": elapsed, "protocolError": protocolError, "actions": actions]
            results.append(result)
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
            print("PROBE_RESULT \(model)/\(repetition)/\(name) \(elapsed)s error=\(protocolError) \(answer)")
        }
    }
    try await provider.unload()
    print("PROBE_COMPLETE \(model) count=\(results.count)")
}
private actor PromptRecorder: ChatCapability {
    let availability: CapabilityAvailability = .available
    var system = ""
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        system = request.messages.first?.content ?? ""
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text("OK."))
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
}

