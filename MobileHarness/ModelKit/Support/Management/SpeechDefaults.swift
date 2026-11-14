import Foundation
import ModelKit
import ModelKitAppleSpeech
import ModelKitEnergy
import ModelKitMossNano
import ModelKitNemotron
@_spi(ModelAssembly) import ModelKitRuntime
import ModelKitSilero

extension DefaultModelAssembly {
    @available(iOS 27, macOS 27, *)
    static func registerSpeechModels(manager: ModelManager, resources: URL) async throws {
        try await manager.register(
            ModelRegistration(id: ModelID("silero"), capabilities: [.voiceActivity], artifactID: "silero") {
                context in
                ProvidedCapabilities(
                    voiceActivity: try SileroVAD(
                        context: context, artifacts: resources.appendingPathComponent("Silero")))
            })
        try await manager.register(
            ModelRegistration(
                id: ModelID("nemotron-local"), capabilities: [.recognition], memoryPolicy: .releaseWhenIdle,
                artifactID: "nemotron"
            ) { context in
                let model = try NemotronASR(
                    context: context, artifacts: resources.appendingPathComponent("Nemotron"))
                return ProvidedCapabilities(warmup: { try await model.warmup() }, recognition: model)
            })
        try await manager.register(
            ModelRegistration(
                id: mossNano, capabilities: [.synthesis], memoryPolicy: .releaseWhenIdle,
                artifactID: "moss-tts-nano"
            ) { context in
                let model = try MossSpeechSynthesis(
                    context: context, artifacts: resources.appendingPathComponent("MossTTSNano"))
                return ProvidedCapabilities(warmup: { try await model.warmup() }, synthesis: model)
            })
        for (locale, id) in SpeechSelection.appleRecognitionModels {
            try await manager.register(
                ModelRegistration(id: id, capabilities: [.recognition]) { context in
                    let model = try AppleSpeechRecognition(context: context, locale: locale)
                    return ProvidedCapabilities(warmup: { try await model.warmup() }, recognition: model)
                })
        }
        try await manager.register(
            ModelRegistration(id: ModelID("apple-synthesis"), capabilities: [.synthesis]) { context in
                ProvidedCapabilities(synthesis: try await AppleSpeechSynthesis(context: context))
            })
        try await manager.register(
            ModelRegistration(id: ModelID("energy-vad"), capabilities: [.voiceActivity]) { context in
                ProvidedCapabilities(voiceActivity: try EnergyVoiceActivity(context: context))
            })
    }
    @available(iOS 27, macOS 27, *)
    static func registerSpeechDefaults(manager: ModelManager, selection: SpeechSelection) async throws {
        let recognition = SelectedRecognition(manager: manager, selection: selection)
        let synthesis = SelectedSynthesis(manager: manager, selection: selection)
        let vad = SelectedVoiceActivity(manager: manager, selection: selection)
        try await manager.register(
            ModelRegistration(id: ModelID("recognition"), capabilities: [.recognition]) { _ in
                ProvidedCapabilities(warmup: { try await recognition.warmup() }, recognition: recognition)
            }, defaults: [.recognition])
        try await manager.register(
            ModelRegistration(id: ModelID("synthesis"), capabilities: [.synthesis]) { _ in
                ProvidedCapabilities(warmup: { try await synthesis.warmup() }, synthesis: synthesis)
            }, defaults: [.synthesis])
        try await manager.register(
            ModelRegistration(id: ModelID("voice-activity"), capabilities: [.voiceActivity]) { _ in
                ProvidedCapabilities(warmup: { try await vad.warmup() }, voiceActivity: vad)
            }, defaults: [.voiceActivity])
    }
}
