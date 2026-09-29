// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "HarnessKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(
            name: "HarnessKit",
            targets: [
                "AgentCore", "Gateway", "Agents", "Actions", "Tools", "ModelKit",
                "Storage", "StorageChat", "StorageAudio", "UI", "AppWorkflows", "BehaviorAssembly",
                "ModelKitAppleSpeech", "ModelKitRuntime", "ModelKitDefaults",
                "ModelKitSilero", "ModelKitNemotron", "ModelKitMossNano",
                "PlatformKit",
            ]),
        .library(name: "ModelKitYOLOPose", targets: ["ModelKitYOLOPose"]),
        .library(name: "ModelKitSilero", targets: ["ModelKitSilero"]),
        .library(name: "ModelKitKokoro", targets: ["ModelKitKokoro"]),
        .library(name: "ModelKitNemotron", targets: ["ModelKitNemotron"]),
        .library(name: "ModelKitOpenAI", targets: ["ModelKitOpenAI"]),
        .library(name: "ModelKit", targets: ["ModelKit"]),
        .library(name: "ModelKitQwen35", targets: ["ModelKitQwen35"]),
        .library(name: "ModelKitRuntime", targets: ["ModelKitRuntime"]),
        .library(name: "ModelKitAppleSpeech", targets: ["ModelKitAppleSpeech"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio", revision: "20d4f0bd46d11d7f50a6eb4f7835cfdbd2b4ba14",
            traits: []),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.1.0"),
    ],
    targets: [
        .target(
            name: "BehaviorAssembly", dependencies: ["AgentCore", "Actions", "Tools"],
            path: "MobileHarness/App/Composition/Behaviors", exclude: ["README.md"]),
        .target(
            name: "UI", dependencies: ["AgentCore", "StorageChat"], path: "MobileHarness/UI",
            exclude: [
                "README.md", "Camera/README.md", "Components/README.md", "Conversation/README.md",
                "Settings/README.md", "Diagnostics/README.md",
            ]),
        .target(
            name: "AppWorkflows",
            dependencies: [
                "UI", "AgentCore", "Agents", "Storage", "StorageChat", "ModelKit", "ModelKitDefaults", "ModelKitOpenAI",
                "PlatformKit",
            ],
            path: "MobileHarness/App/Workflows", exclude: ["README.md"]),
        .testTarget(name: "UITests", dependencies: ["UI"], exclude: ["README.md"]),
        .testTarget(
            name: "AppWorkflowTests",
            dependencies: ["AppWorkflows", "UI", "Storage", "StorageChat", "ModelKit"],
            exclude: ["README.md"]),
        .target(
            name: "AgentCore", path: "MobileHarness/Agents/Core",
            exclude: [
                "Communication/README.md", "Capability/README.md", "Generation/README.md", "Output/README.md",
                "README.md",
                "Runtime/README.md",
            ]),
        .target(
            name: "Gateway", dependencies: ["AgentCore", "Actions", "Tools"],
            path: "MobileHarness/Gateway",
            exclude: [
                "Input/README.md", "Output/Dispatch/README.md", "Output/README.md",
                "Output/Routing/README.md", "Output/Scheduling/README.md", "Output/Validation/README.md",
                "Output/Resources/README.md", "Output/Results/README.md", "README.md",
            ]),
        .target(
            name: "Actions", dependencies: ["AgentCore", "StorageAudio"],
            path: "MobileHarness/Actions",
            exclude: ["UI/README.md", "README.md", "Speech/README.md", "Runtime/README.md", "NexArm/README.md"]),
        .target(
            name: "Agents", dependencies: ["AgentCore", "ModelKit", "StorageChat", "StorageAudio"],
            path: "MobileHarness/Agents",
            exclude: [
                "Core", "SpeechSynthesis/README.md", "Assistant/README.md",
                "SpeechPerception/README.md",
                "VisionPerception/README.md", "README.md",
            ],
            resources: [
                .process("Assistant/Assistant.agent.json"),
                .process("SpeechSynthesis/SpeechSynthesis.agent.json"),
                .process("SpeechPerception/SpeechPerception.agent.json"),
                .process("VisionPerception/VisionPerception.agent.json"),
            ]),
        .target(
            name: "Storage", path: "MobileHarness/Storage",
            exclude: ["README.md", "Audio", "Chat"]),
        .target(
            name: "StorageChat", dependencies: ["Storage"],
            path: "MobileHarness/Storage/Chat", exclude: ["README.md"]),
        .target(
            name: "StorageAudio", dependencies: ["Storage", "AgentCore", "ModelKit"],
            path: "MobileHarness/Storage/Audio", exclude: ["README.md"]),
        .target(
            name: "Tools", dependencies: ["AgentCore"], path: "MobileHarness/Tools",
            exclude: ["README.md", "System/README.md", "UI/README.md", "Runtime/README.md"]),
        .target(
            name: "ModelKit", path: "MobileHarness/ModelKit",
            exclude: [
                "README.md", "Language/README.md", "Language/JEV/README.md",
                "Speech/README.md", "Speech/ASR/README.md", "Speech/TTS/README.md", "Speech/VAD/README.md",
                "Language/LLM/Qwen35", "Language/LLM/OpenAI", "Language/LLM/README.md", "Backends",
                "Core/README.md", "Management", "Defaults", "Speech/ASR/Apple", "Speech/TTS/Apple", "Speech/TTS/Kokoro",
                "Speech/TTS/MossNano",
                "Speech/Shared",
                "Speech/ASR/Nemotron", "Speech/VAD/Silero", "Vision/YOLO", "Vision/README.md",
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
                "ModelKitMossNano", "ModelKitQwen35", "ModelKitYOLOPose", "ModelKitOpenAI",
            ],
            path: "MobileHarness/ModelKit/Defaults", exclude: ["README.md"]),
        .target(
            name: "ModelKitRuntime", dependencies: ["ModelKit"], path: "MobileHarness/ModelKit/Management",
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
            name: "ModelKitCoreAI", path: "MobileHarness/ModelKit/Backends/CoreAI", exclude: ["README.md"]),
        .target(
            name: "ModelKitNemotron", dependencies: ["ModelKit", "ModelKitCoreAI"],
            path: "MobileHarness/ModelKit/Speech/ASR/Nemotron", exclude: ["README.md"],
            resources: [.process("Resources")]),
        .testTarget(name: "NemotronTests", dependencies: ["ModelKit", "ModelKitNemotron"], exclude: ["README.md"]),
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
                "AgentCore", "Gateway", "Agents", "Actions", "Tools", "ModelKit",
                "Storage", "StorageChat", "StorageAudio",
                "PlatformKit",
            ],
            exclude: ["README.md"]),
        .target(
            name: "ModelKitMLXLanguage",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
            ], path: "MobileHarness/ModelKit/Backends/MLX", exclude: ["README.md"]),
        .target(
            name: "ModelKitQwen35", dependencies: ["ModelKit", "ModelKitMLXLanguage"],
            path: "MobileHarness/ModelKit/Language/LLM/Qwen35", exclude: ["README.md"]),
        .testTarget(
            name: "Qwen35Tests", dependencies: ["ModelKit", "ModelKitQwen35", "ModelKitMLXLanguage"],
            exclude: ["README.md"], resources: [.copy("Fixtures")]),
        .testTarget(
            name: "AgentModelEvaluationTests", dependencies: ["AgentCore", "Agents", "ModelKit", "ModelKitQwen35"],
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
