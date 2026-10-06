// swift-tools-version: 6.4

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "HarnessKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(
            name: "HarnessKit",
            targets: [
                "AgentCore", "Gateway", "Agents", "Actions", "Tools", "ActionRuntime", "ToolRuntime",
                "ModelKit",
                "Storage", "StorageChat", "StorageAudio", "UI", "AppWorkflows", "BehaviorAssembly",
                "ModelKitAppleSpeech", "ModelKitRuntime", "ModelKitDefaults", "ModelKitHub",
                "ModelKitSilero", "ModelKitNemotron", "ModelKitMossNano",
                "PlatformKit",
            ]),
        .library(name: "ModelKitYOLOPose", targets: ["ModelKitYOLOPose"]),
        .library(name: "ModelKitSilero", targets: ["ModelKitSilero"]),
        .library(name: "ModelKitKokoro", targets: ["ModelKitKokoro"]),
        .library(name: "ModelKitNemotron", targets: ["ModelKitNemotron"]),
        .library(name: "ModelKitOpenAI", targets: ["ModelKitOpenAI"]),
        .library(name: "ModelKit", targets: ["ModelKit"]),
        .library(name: "ModelKitGemma4", targets: ["ModelKitGemma4"]),
        .library(name: "ModelKitRuntime", targets: ["ModelKitRuntime"]),
        .library(name: "ModelKitAppleSpeech", targets: ["ModelKitAppleSpeech"]),
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.9.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.2"),
        .package(
            url: "https://github.com/FluidInference/FluidAudio", revision: "20d4f0bd46d11d7f50a6eb4f7835cfdbd2b4ba14",
            traits: []),
        .package(url: "https://github.com/john-rocky/coreai-models", exact: "0.2.8-zoo"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.1.0"),
    ],
    targets: [
        .target(
            name: "ModelKitHub",
            dependencies: ["ModelKitRuntime", .product(name: "HuggingFace", package: "swift-huggingface")],
            path: "MobileHarness/ModelKit/Backends/HuggingFace", exclude: ["README.md"]),
        .macro(
            name: "BehaviorDefinitions",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ], path: "Macros/BehaviorDefinitions", exclude: ["README.md"]),
        .target(
            name: "BehaviorAssembly", dependencies: ["Actions", "Tools", "ActionRuntime", "ToolRuntime"],
            path: "MobileHarness/App/Composition/Behaviors", exclude: ["README.md"]),
        .target(
            name: "UI", dependencies: ["StorageChat"], path: "MobileHarness/UI",
            exclude: [
                "README.md", "Camera/README.md", "Components/README.md", "Conversation/README.md",
                "Settings/README.md", "Diagnostics/README.md",
            ]),
        .target(
            name: "AppSettingsWorkflow", dependencies: ["UI", "Storage"], path: "MobileHarness/App/Workflows/Settings",
            exclude: ["README.md"]),
        .target(
            name: "AppHistoryWorkflow", dependencies: ["UI", "StorageChat"],
            path: "MobileHarness/App/Workflows/History", exclude: ["README.md"]),
        .target(
            name: "AppBluetoothWorkflow",
            dependencies: ["UI", "AgentCore", "Storage", "Actions", "ActionRuntime", "PlatformKit"],
            path: "MobileHarness/App/Workflows/Bluetooth", exclude: ["README.md"]),
        .target(
            name: "AppSpeechPlayback", dependencies: ["ActionRuntime", "StorageAudio"],
            path: "MobileHarness/App/Workflows/Speech", exclude: ["README.md"]),
        .target(
            name: "AppPresentationWorkflow", dependencies: ["UI", "AgentCore", "ActionRuntime", "ToolRuntime"],
            path: "MobileHarness/App/Workflows/Presentation", exclude: ["README.md"]),
        .target(
            name: "AppDiagnosticWorkflow", dependencies: ["UI", "ModelKit", "PlatformKit"],
            path: "MobileHarness/App/Workflows/Diagnostics", exclude: ["README.md"]),
        .target(
            name: "AppWorkflows",
            dependencies: [
                "AppSettingsWorkflow", "AppHistoryWorkflow", "AppBluetoothWorkflow", "AppSpeechPlayback",
                "AppPresentationWorkflow", "AppDiagnosticWorkflow",
            ], path: "MobileHarness/App/Workflows",
            exclude: ["README.md", "Settings", "History", "Bluetooth", "Speech", "Presentation", "Diagnostics"]),
        .testTarget(
            name: "ModelKitHubTests",
            dependencies: [
                "ModelKitHub", "ModelKitRuntime", .product(name: "HuggingFace", package: "swift-huggingface"),
            ], exclude: ["README.md"]),
        .testTarget(name: "UITests", dependencies: ["UI"], exclude: ["README.md"]),
        .testTarget(
            name: "AppWorkflowTests",
            dependencies: [
                "AppWorkflows", "UI", "Storage", "StorageChat", "ModelKit", "Agents", "AppSettingsWorkflow",
            ],
            exclude: ["README.md"]),
        .target(
            name: "AgentCore", dependencies: [], path: "MobileHarness/Agents/Core",
            exclude: [
                "Input/README.md", "Communication/README.md", "Capability/README.md", "Generation/README.md",
                "Output/README.md",
                "README.md",
                "Runtime/README.md",
            ]),
        .target(
            name: "ActionRuntime", path: "MobileHarness/Actions/Runtime", exclude: ["README.md", "Contracts/README.md"]),
        .target(
            name: "ToolRuntime", path: "MobileHarness/Tools/Runtime", exclude: ["README.md", "Contracts/README.md"]),
        .target(
            name: "Gateway", dependencies: ["AgentCore", "ActionRuntime", "ToolRuntime"],
            path: "MobileHarness/Gateway",
            exclude: [
                "Input/README.md", "Output/Dispatch/README.md", "Output/README.md",
                "Output/Routing/README.md", "Output/Scheduling/README.md", "Output/Validation/README.md",
                "Output/Resources/README.md", "Output/Results/README.md", "README.md",
            ]),
        .target(
            name: "Actions", dependencies: ["ActionRuntime", "PlatformKit", "BehaviorDefinitions"],
            path: "MobileHarness/Actions",
            exclude: [
                "Runtime",
                "README.md", "NexArm/README.md", "NexArm/Support/README.md",
                "Speech/README.md", "Speech/Support/README.md", "UI/README.md", "UI/Support/README.md",
            ]),
        .target(
            name: "Agents",
            dependencies: ["AgentCore", "ModelKit", "PlatformKit", "StorageChat", "StorageAudio"],
            path: "MobileHarness/Agents",
            exclude: [
                "Core", "Communication/README.md", "SpeechSynthesis/README.md", "Assistant/README.md",
                "SpeechPerception/README.md",
                "VisionPerception/README.md", "Photographer/README.md", "README.md",
            ],
            resources: [
                .process("Assistant/Assistant.agent.json"),
                .process("SpeechSynthesis/SpeechSynthesis.agent.json"),
                .process("SpeechPerception/SpeechPerception.agent.json"),
                .process("VisionPerception/VisionPerception.agent.json"),
                .process("Photographer/Photographer.agent.json"),
            ]),
        .target(
            name: "Storage", path: "MobileHarness/Storage",
            exclude: ["README.md", "Audio", "Chat"]),
        .target(
            name: "StorageChat", dependencies: ["Storage"],
            path: "MobileHarness/Storage/Chat", exclude: ["README.md"]),
        .target(
            name: "StorageAudio", dependencies: ["Storage"],
            path: "MobileHarness/Storage/Audio", exclude: ["README.md"]),
        .target(
            name: "Tools", dependencies: ["ToolRuntime", "BehaviorDefinitions", "StorageChat"],
            path: "MobileHarness/Tools",
            exclude: [
                "Runtime",
                "Camera/README.md", "Camera/Support/README.md",
                "History/README.md", "History/Support/README.md",
                "Robot/README.md", "Robot/Support/README.md",
                "README.md", "System/README.md", "System/Support/README.md", "UI/README.md", "UI/Support/README.md",
            ]),
        .target(
            name: "ModelKit", path: "MobileHarness/ModelKit",
            exclude: [
                "README.md", "Language/README.md", "Language/JEV/README.md",
                "Speech/README.md", "Speech/ASR/README.md", "Speech/TTS/README.md", "Speech/VAD/README.md",
                "Language/LLM/Gemma4", "Language/LLM/OpenAI", "Language/LLM/README.md", "Backends",
                "Core/README.md", "Management", "Defaults", "Speech/ASR/Apple", "Speech/TTS/Apple", "Speech/TTS/Kokoro",
                "Speech/TTS/MossNano",
                "Speech/Shared",
                "Speech/ASR/Nemotron", "Speech/VAD/Silero", "Speech/VAD/Energy", "Vision/YOLO", "Vision/README.md",
            ]),
        .target(
            name: "ModelKitOpenAI", dependencies: ["ModelKit"],
            path: "MobileHarness/ModelKit/Language/LLM/OpenAI", exclude: ["README.md"]),
        .testTarget(
            name: "OpenAIChatTests", dependencies: ["ModelKit", "ModelKitOpenAI", "ModelKitRuntime"],
            exclude: ["README.md"]),
        .target(
            name: "ModelKitDefaults",
            dependencies: [
                "ModelKit", "ModelKitRuntime", "ModelKitNemotron", "ModelKitSilero",
                "ModelKitMossNano", "ModelKitGemma4", "ModelKitYOLOPose", "ModelKitOpenAI", "ModelKitAppleSpeech",
                "ModelKitEnergy",
            ],
            path: "MobileHarness/ModelKit/Defaults", exclude: ["README.md"]),
        .target(
            name: "ModelKitRuntime", dependencies: ["ModelKit"], path: "MobileHarness/ModelKit/Management",
            exclude: ["README.md"]),
        .target(
            name: "ModelKitEnergy", dependencies: ["ModelKit"], path: "MobileHarness/ModelKit/Speech/VAD/Energy",
            exclude: ["README.md"]),
        .target(
            name: "ModelKitAppleSpeech", dependencies: ["ModelKit"], path: "MobileHarness/ModelKit/Speech",
            exclude: [
                "README.md", "ASR/README.md", "TTS/README.md", "Shared/README.md",
                "Shared/Apple/README.md", "ASR/Apple/README.md", "TTS/Apple/README.md",
                "ASR/SpeechRecognitionCapability.swift",
                "TTS/SpeechSynthesisCapability.swift", "TTS/Kokoro", "TTS/MossNano", "ASR/Nemotron", "VAD",
            ],
            sources: ["ASR/Apple", "TTS/Apple", "Shared/Apple"]),
        .target(
            name: "ModelKitYOLOPose", dependencies: ["ModelKit", "ModelKitCoreML"],
            path: "MobileHarness/ModelKit/Vision/YOLO", exclude: ["README.md"]),
        .testTarget(
            name: "YOLOPoseTests", dependencies: ["ModelKit", "ModelKitYOLOPose", "ModelKitCoreML", "ModelKitRuntime"],
            exclude: ["README.md"]),
        .target(
            name: "ModelKitFluidAudio",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "MobileHarness/ModelKit/Backends/FluidAudio", exclude: ["README.md"]),
        .target(name: "ModelKitCoreML", path: "MobileHarness/ModelKit/Backends/CoreML", exclude: ["README.md"]),
        .target(
            name: "ModelKitSilero", dependencies: ["ModelKit", "ModelKitCoreML"],
            path: "MobileHarness/ModelKit/Speech/VAD/Silero", exclude: ["README.md"]),
        .testTarget(
            name: "SileroTests",
            dependencies: [
                "ModelKit", "ModelKitSilero", "ModelKitNemotron", "ModelKitKokoro", "Agents", "PlatformKit",
            ], exclude: ["README.md"]),
        .target(
            name: "ModelKitCoreAI",
            dependencies: [
                .product(name: "CoreAILM", package: "coreai-models"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ], path: "MobileHarness/ModelKit/Backends/CoreAI", exclude: ["README.md"]),
        .target(
            name: "ModelKitNemotron", dependencies: ["ModelKit", "ModelKitFluidAudio"],
            path: "MobileHarness/ModelKit/Speech/ASR/Nemotron", exclude: ["README.md"]),
        .testTarget(name: "EnergyVADTests", dependencies: ["ModelKit", "ModelKitEnergy"], exclude: ["README.md"]),
        .testTarget(
            name: "NemotronTests", dependencies: ["ModelKit", "ModelKitNemotron", "ModelKitFluidAudio"],
            exclude: ["README.md"]),
        .target(name: "ModelKitMossCoreML", path: "MobileHarness/ModelKit/Backends/MossCoreML", exclude: ["README.md"]),
        .target(
            name: "ModelKitMossNano", dependencies: ["ModelKit", "ModelKitMossCoreML"],
            path: "MobileHarness/ModelKit/Speech/TTS/MossNano", exclude: ["README.md"]),
        .testTarget(
            name: "MossNanoTests", dependencies: ["ModelKit", "ModelKitMossNano", "ModelKitMossCoreML"],
            exclude: ["README.md"]),
        .target(
            name: "ModelKitKokoro", dependencies: ["ModelKit", "ModelKitFluidAudio"],
            path: "MobileHarness/ModelKit/Speech/TTS/Kokoro", exclude: ["README.md"]),
        .testTarget(name: "KokoroTests", dependencies: ["ModelKit", "ModelKitKokoro"], exclude: ["README.md"]),
        .target(
            name: "PlatformKit", path: "MobileHarness/PlatformKit",
            exclude: [
                "README.md", "Audio/README.md", "Vision/README.md", "Core/README.md", "Connectivity/README.md",
                "Connectivity/NexArm/README.md",
            ]),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "BehaviorAssembly", "AppWorkflows", "UI",
                "AgentCore", "Gateway", "Agents", "Actions", "Tools", "ActionRuntime", "ToolRuntime",
                "ModelKit",
                "Storage", "StorageChat", "StorageAudio",
                "PlatformKit",
            ],
            exclude: ["README.md"]),
        .target(
            name: "ModelKitGemma4", dependencies: ["ModelKit", "ModelKitCoreAI"],
            path: "MobileHarness/ModelKit/Language/LLM/Gemma4", exclude: ["README.md"]),
        .testTarget(
            name: "Gemma4Tests", dependencies: ["ModelKit", "ModelKitGemma4", "ModelKitCoreAI"],
            exclude: ["README.md"]),
        .testTarget(
            name: "AgentModelEvaluationTests", dependencies: ["AgentCore", "Agents", "ModelKit", "ModelKitGemma4"],
            exclude: ["README.md"], resources: [.copy("Scenarios")]),
        .testTarget(
            name: "ModelKitDefaultsTests", dependencies: ["ModelKit", "ModelKitRuntime", "ModelKitDefaults"],
            exclude: ["README.md"]),
        .testTarget(name: "ModelKitTests", dependencies: ["ModelKit"], exclude: ["README.md"]),
        .testTarget(
            name: "ModelKitRuntimeTests", dependencies: ["ModelKit", "ModelKitRuntime"], exclude: ["README.md"]),
        .testTarget(
            name: "ModelKitAppleSpeechTests", dependencies: ["ModelKit", "ModelKitAppleSpeech"], exclude: ["README.md"]),
    ],
    swiftLanguageModes: [.v6]
)
