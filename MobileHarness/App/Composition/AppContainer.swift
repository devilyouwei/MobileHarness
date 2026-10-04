import AppWorkflows
import Foundation
import ModelKit
import ModelKitDefaults
import PlatformKit
import Synchronization
import UI
import UIKit

/// Resolves default capabilities once; consumers receive shared, managed capability instances.
@MainActor
final class AppContainer {
    private var memoryWarnings: Task<Void, Never>?
    let lifecycle: VoiceSessionCoordinator
    let conversation: ConversationState
    let actionActivity: ActionActivityState
    private let diagnostic: SpeechDiagnosticWorkflow
    let audioDetection: AudioDetectionWorkflow

    func makeMossValidationView() -> MossValidationView {
        MossValidationView(
            state: diagnostic.state, controls: diagnostic,
            autorun: ProcessInfo.processInfo.arguments.contains("-moss-autorun"))
    }

    #if DEBUG
        private let validateVoiceModels: @Sendable () async throws -> String
        func makeChatValidationView() -> ChatValidationView {
            ChatValidationView(validate: validateVoiceModels)
        }
    #endif

    deinit { memoryWarnings?.cancel() }

    init(
        resources: URL, runtime: ApplicationRuntime, modelName: @escaping @Sendable () async throws -> String,
        progress: @MainActor (String) -> Void
    ) async throws {
        actionActivity = runtime.actionActivity.state
        let models = try await ModelKitDefaults.manager(resources: resources)
        // Resolve stable capability handles before preparing the conversation models.
        let recognition = try await models.get(.recognition, load: false)
        let chat = CurrentChatCapability(models: models)
        let vad = try await models.get(.voiceActivity, load: false)
        let synthesis = try await models.get(.synthesis, load: false)
        let validationModel = synthesis
        let diagnosticState = SpeechDiagnosticState()
        diagnostic = SpeechDiagnosticWorkflow(
            state: diagnosticState, player: AppleAudioIO(), provider: validationModel,
            load: { try await models.warmup(.synthesis) },
            unload: { try await ModelKitDefaults.unloadSpeechSynthesis(resources: resources) })
        #if DEBUG
            validateVoiceModels = {
                try await ChatDiagnosticWorkflow.validate(chat: chat) {
                    try await models.warmup(.recognition)
                    try await models.warmup(.chat)
                }
            }
        #endif
        // Preparation is deferred to explicit voice admission; missing downloads do not block Settings/history.
        progress("本地模型可在设置中下载")
        try Task.checkCancellation()
        let state = ConversationState()
        let lifecycle = VoiceSessionCoordinator(
            runtime: runtime.voiceDependencies, state: state, modelName: modelName,
            audio: AppleAudioIO(), recognition: recognition, synthesis: synthesis,
            prepareRecognition: {
                // Reload only resources evicted after startup; get/load reuse resident weights.
                try await models.warmup(.recognition)
                try await models.warmup(.chat)
                try await models.warmup(.voiceActivity)
                try await models.warmup(.synthesis)
            }, voiceActivity: vad, chat: chat)
        self.lifecycle = lifecycle
        let audioDetection = AudioDetectionWorkflow(
            state: AudioDetectionState(),
            endpoint: AudioDetectionSession(
                recognition: recognition, vad: vad,
                beforeStart: { [weak lifecycle] in await lifecycle?.stopVoiceAndWait() }))
        self.audioDetection = audioDetection
        lifecycle.beforeVoiceStart = { [weak audioDetection] in await audioDetection?.stopAndWait() }
        conversation = state
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
