import Foundation
import ModelKit
import ModelKitDefaults
import ModelKitRuntime
import PlatformKit
import Synchronization
import UIKit

/// Resolves default capabilities once; consumers receive shared, managed capability instances.
@MainActor
final class AppContainer {
    private let models: ModelManager
    private var memoryWarnings: Task<Void, Never>?
    private let validationModel: any SpeechSynthesisCapability
    private let kokoroID = ModelKitDefaults.kokoro
    let lifecycle: AppLifecycleCoordinator
    let conversation: ConversationViewModel

    func makeKokoroValidationView() -> KokoroValidationView {
        let models = models
        let id = kokoroID
        return KokoroValidationView(
            provider: validationModel,
            load: { try await models.load(id) },
            unload: { try await models.unload(id) })
    }

    #if DEBUG
        private let validateVoiceModels: @Sendable () async throws -> String
        func makeQwen35ValidationView() -> Qwen35ValidationView {
            Qwen35ValidationView(validate: validateVoiceModels)
        }
    #endif

    deinit { memoryWarnings?.cancel() }

    init(progress: @MainActor (String) -> Void) async throws {
        let resources = Bundle.main.bundleURL.appendingPathComponent("Models")
        let models = try await ModelKitDefaults.manager(resources: resources)
        // Resolve stable capability handles before preparing the conversation models.
        let recognition = try await models.get(.recognition, load: false)
        let chat = CurrentChatCapability(models: models)
        let vad = try await models.get(.voiceActivity, load: false)
        let synthesis = try await models.get(.synthesis, load: false)
        validationModel = try await models.get(kokoroID, as: .synthesis, load: false)
        self.models = models
        #if DEBUG
            validateVoiceModels = {
                let started = Date()
                try await models.warmup(.recognition)
                try await models.warmup(.chat)
                let session = try await chat.chat(
                    ChatRequest(
                        messages: [
                            .init(role: .system, content: "你是中文助手，直接简短回答。"),
                            .init(role: .user, content: "我有3个苹果，又买了2个，吃掉1个，还剩几个？只回答数字。"),
                        ], maximumOutputTokens: 32, temperature: 0))
                defer { session.cancel() }
                var answer = ""
                for try await event in session.events {
                    if case .text(let delta) = event { answer += delta }
                }
                guard !answer.isEmpty else { throw CapabilityError.unavailable("Empty validation reply") }
                return "ASR + Qwen ready. Reply: \(answer). Total: \(Date().timeIntervalSince(started)) s"
            }
        #endif
        if !ProcessInfo.processInfo.arguments.contains("-kokoro-benchmark") {
            progress("正在加载语音识别模型…")
            try await models.warmup(.recognition)
            progress("正在加载对话模型…")
            try await models.warmup(.chat)
            progress("正在加载语音检测模型…")
            try await models.load(.voiceActivity)
            progress("正在准备语音合成…")
            try await models.load(.synthesis)
        }
        try Task.checkCancellation()
        let lifecycle = AppLifecycleCoordinator(
            audio: AppleAudioIO(), recognition: recognition, synthesis: synthesis,
            prepareRecognition: {
                // Reload only resources evicted after startup; get/load reuse resident weights.
                try await models.load(.recognition)
                try await models.load(.chat)
                try await models.load(.voiceActivity)
                try await models.load(.synthesis)
            }, voiceActivity: vad, chat: chat)
        self.lifecycle = lifecycle
        conversation = ConversationViewModel(lifecycle: lifecycle)
        let warnings = memoryWarningStream()
        memoryWarnings = Task {
            for await _ in warnings {
                guard !Task.isCancelled else { break }
                await models.handleMemoryPressure()
            }
        }
    }
}

/// Memory warnings are coalescible notifications: retain only the latest pending warning.
private func memoryWarningStream() -> AsyncStream<Void> {
    let token = Mutex<(any NSObjectProtocol)?>(nil)
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        token.withLock {
            $0 = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
            ) { _ in continuation.yield(()) }
        }
        continuation.onTermination = { _ in
            let observer = token.withLock { value in
                let observer = value
                value = nil
                return observer
            }
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// Capability-only consumers resolve the current binding on every operation after settings changes.
private struct CurrentChatCapability: ChatCapability {
    let models: ModelManager
    var availability: CapabilityAvailability {
        get async {
            do { return try await models.availability(.chat) } catch { return .unavailable(reason: "对话模型暂不可用") }
        }
    }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        let provider = try await models.get(.chat)
        return try await provider.chat(request)
    }
}
