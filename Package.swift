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
                "AgentCore", "Gateway", "Agents", "Actions", "FunctionContracts", "ExecutionRuntime", "CallRuntime",
                "ModelKit",
                "Storage", "StorageChat", "StorageAudio", "StorageTasks", "StorageMedia", "StorageDevices",
                "StorageSQLite", "UI", "AppWorkflows", "BehaviorAssembly",
                "ModelKitAppleSpeech", "ModelKitRuntime", "ModelKitDefaults", "ModelKitHub",
                "ModelKitSilero", "ModelKitNemotron", "ModelKitMossNano",
                "PlatformKit",
            ]),
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "StorageChat", targets: ["StorageChat"]),
        .library(name: "StorageAudio", targets: ["StorageAudio"]),
        .library(name: "StorageTasks", targets: ["StorageTasks"]),
        .library(name: "StorageMedia", targets: ["StorageMedia"]),
        .library(name: "StorageDevices", targets: ["StorageDevices"]),
        .library(name: "StorageSQLite", targets: ["StorageSQLite"]),
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
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
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
            path: "MobileHarness/ModelKit/Support/Management/HuggingFace", exclude: ["README.md"]),
        .macro(
            name: "BehaviorDefinitions",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ], path: "Macros/BehaviorDefinitions", exclude: ["README.md"]),
        .target(
            name: "BehaviorAssembly",
            dependencies: ["Actions", "FunctionContracts", "ExecutionRuntime", "CallRuntime"],
            path: "MobileHarness/App/Composition/Behaviors", exclude: ["README.md"]),
        .target(
            name: "UI", dependencies: [], path: "MobileHarness/UI",
            exclude: [
                "README.md", "Camera/README.md", "Components/README.md", "Conversation/README.md",
                "Settings/README.md", "Diagnostics/README.md",
            ], resources: [.process("Components/ListeningHalo.metal")]),
        .target(
            name: "AppSettingsWorkflow",
            dependencies: ["Storage", "UI", "AgentCore", "Agents", "Gateway", "AppPresentationWorkflow"],
            path: "MobileHarness/App/Workflows/Settings",
            exclude: ["README.md"]),
        .target(
            name: "AppHistoryWorkflow",
            dependencies: [
                "Storage",
                "UI", "StorageChat", "AgentCore", "Agents", "Gateway", "Actions", "AppPresentationWorkflow",
                "FunctionContracts",
                "ExecutionRuntime", "CallRuntime",
            ],
            path: "MobileHarness/App/Workflows/History", exclude: ["README.md"]),
        .target(
            name: "AppBluetoothWorkflow",
            dependencies: [
                "Storage",
                "UI", "AgentCore", "Actions", "FunctionContracts", "ExecutionRuntime", "CallRuntime",
                "PlatformKit", "StorageDevices",
            ],
            path: "MobileHarness/App/Workflows/Bluetooth", exclude: ["README.md"]),
        .target(
            name: "AppSpeechPlayback",
            dependencies: ["Storage", "FunctionContracts", "StorageAudio", "Actions", "ExecutionRuntime"],
            path: "MobileHarness/App/Workflows/Speech", exclude: ["README.md"]),
        .target(
            name: "AppPresentationWorkflow",
            dependencies: ["Storage", "UI", "AgentCore", "FunctionContracts"],
            path: "MobileHarness/App/Workflows/Presentation", exclude: ["README.md"]),
        .target(
            name: "AppDiagnosticWorkflow", dependencies: ["Storage", "UI", "ModelKit", "PlatformKit"],
            path: "MobileHarness/App/Workflows/Diagnostics", exclude: ["README.md"]),
        .target(
            name: "AppWorkflows",
            dependencies: [
                "Storage",
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
                "Storage",
                "AppWorkflows", "UI", "StorageChat", "ModelKit", "Agents", "AppSettingsWorkflow",
            ],
            exclude: ["README.md"]),
        .target(
            name: "AgentCore", dependencies: [], path: "MobileHarness/Agents/Support/Core",
            exclude: [
                "Input/README.md", "Communication/README.md", "Capability/README.md", "Generation/README.md",
                "Output/README.md",
                "README.md",
                "Runtime/README.md",
            ], resources: [.process("Generation/FunctionTokenPrompts.json")]),
        .target(
            name: "FunctionContracts", dependencies: [], path: "MobileHarness/Actions/Support/Contracts",
            exclude: ["README.md"]),
        .target(
            name: "ExecutionRuntime", dependencies: ["FunctionContracts"],
            path: "MobileHarness/Gateway/Runtime", exclude: ["README.md"]),
        .target(
            name: "CallRuntime", dependencies: ["FunctionContracts", "ExecutionRuntime"],
            path: "MobileHarness/Gateway/Output",
            exclude: [
                "Dispatch", "Resources", "Results", "Routing", "Scheduling", "Validation", "OutputGateway.swift",
                "README.md", "Registration/README.md", "Protocols/README.md",
            ], sources: ["Registration", "Protocols"]),
        .target(
            name: "Gateway",
            dependencies: ["AgentCore", "FunctionContracts", "ExecutionRuntime", "CallRuntime"],
            path: "MobileHarness/Gateway",
            exclude: [
                "Runtime", "Output/Registration", "Output/Protocols",
                "Input/README.md", "Output/Dispatch/README.md", "Output/README.md",
                "Output/Routing/README.md", "Output/Scheduling/README.md", "Output/Validation/README.md",
                "Output/Resources/README.md", "Output/Results/README.md", "README.md",
            ]),
        .target(
            name: "Actions",
            dependencies: [
                "Storage", "FunctionContracts", "PlatformKit", "BehaviorDefinitions", "StorageChat",
            ],
            path: "MobileHarness/Actions",
            exclude: [
                "Support/Contracts", "Support/README.md", "Camera/README.md", "Camera/Support/README.md",
                "History/README.md",
                "History/Support/README.md", "NexArm/README.md", "NexArm/Support/README.md", "README.md",
                "Speech/README.md", "Speech/Support/README.md",
                "System/README.md", "System/Support/README.md", "UI/README.md", "UI/Support/README.md",
            ]),
        .target(
            name: "Agents",
            dependencies: [
                "Storage",
                "AgentCore", "FunctionContracts", "ModelKit", "PlatformKit", "StorageChat", "StorageAudio",
                "StorageTasks",
            ],
            path: "MobileHarness",
            exclude: [
                "Actions", "App", "Gateway", "ModelKit", "PlatformKit", "Storage", "UI", "README.md",
                "Resources/README.md", "Resources/Models", "Resources/Assets.xcassets",
                "Resources/AppIconVariants", "Resources/PrivacyInfo.xcprivacy",
                "Agents/Support/Core", "Agents/Support/Communication/README.md", "Agents/SpeechSynthesis/README.md",
                "Agents/Assistant/README.md",
                "Agents/SpeechPerception/README.md",
                "Agents/VisionPerception/README.md", "Agents/Photographer/README.md", "Agents/Memory/README.md",
                "Agents/ApplicationControl/README.md", "Agents/Support/README.md", "Agents/Support/Chat/README.md",
                "Agents/Support/Context/README.md", "Agents/README.md",
            ],
            sources: ["Agents"],
            resources: [.copy("Resources/Agents"), .copy("Resources/Skills"), .copy("Resources/Catalog.json")]),
        .target(
            name: "Storage", dependencies: [], path: "MobileHarness/Storage/Support",
            exclude: [
                "README.md", "Contracts/README.md", "Memory/README.md", "Persistence/README.md",
                "Persistence/File/README.md", "Persistence/SQLite",
            ]),
        .target(
            name: "StorageTasks", dependencies: ["Storage"], path: "MobileHarness/Storage/Tasks",
            exclude: ["README.md", "SQLiteTaskRepository.swift"]),
        .target(
            name: "StorageChat", dependencies: ["Storage", "StorageTasks"], path: "MobileHarness/Storage/Chat",
            exclude: ["README.md", "SQLiteChatRepository.swift"]),
        .target(
            name: "StorageAudio", dependencies: ["Storage"], path: "MobileHarness/Storage/Audio", exclude: ["README.md"]
        ),
        .target(
            name: "StorageMedia", dependencies: ["Storage"], path: "MobileHarness/Storage/Media",
            exclude: ["README.md", "SQLiteMediaRepository.swift"]),
        .target(
            name: "StorageDevices", dependencies: ["Storage"], path: "MobileHarness/Storage/Devices",
            exclude: ["README.md", "SQLiteDeviceRepository.swift"]),
        .target(
            name: "StorageSQLite",
            dependencies: [
                "Storage", "StorageChat", "StorageTasks", "StorageMedia", "StorageDevices",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "MobileHarness/Storage",
            exclude: [
                "README.md", "Audio", "Chat/README.md", "Chat/ConversationHistory.swift",
                "Chat/ConversationRecordStore.swift", "Chat/ChatRepository.swift", "Tasks/README.md",
                "Tasks/TaskRepository.swift", "Tasks/MemoryTaskRepository.swift", "Media/README.md",
                "Media/CapturedPhotoStore.swift", "Media/MediaRepository.swift", "Devices/README.md",
                "Devices/DeviceRepository.swift", "Support/README.md", "Support/Contracts", "Support/Memory",
                "Support/Persistence/README.md", "Support/Persistence/File", "Support/Persistence/SQLite/README.md",
            ],
            sources: [
                "SQLiteRepositories.swift", "Chat/SQLiteChatRepository.swift", "Tasks/SQLiteTaskRepository.swift",
                "Media/SQLiteMediaRepository.swift", "Devices/SQLiteDeviceRepository.swift",
                "Support/Persistence/SQLite",
            ]),
        .target(
            name: "ModelKit", dependencies: [], path: "MobileHarness/ModelKit",
            exclude: [
                "README.md", "Language/README.md", "Language/JEV/README.md",
                "Speech/README.md", "Speech/ASR/README.md", "Speech/TTS/README.md", "Speech/VAD/README.md",
                "Language/LLM/Gemma4", "Language/LLM/OpenAI", "Language/LLM/README.md", "Support/Backends",
                "Support/README.md", "Support/Speech",
                "Support/Core/README.md", "Support/Management", "Speech/ASR/Apple", "Speech/TTS/Apple",
                "Speech/TTS/Kokoro",
                "Speech/TTS/MossNano",
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
            path: "MobileHarness/ModelKit/Support/Management",
            exclude: [
                "README.md", "HuggingFace", "ModelManager.swift", "ModelRegistration.swift",
                "ModelArtifactContracts.swift", "ModelArtifactStore.swift", "ArtifactDownloadTransport.swift",
            ],
            sources: [
                "ModelKitDefaults.swift", "ChatDefaults.swift", "SpeechDefaults.swift", "VisionDefaults.swift",
                "SpeechProviderSelection.swift",
            ]),
        .target(
            name: "ModelKitRuntime", dependencies: ["ModelKit"],
            path: "MobileHarness/ModelKit/Support/Management",
            exclude: [
                "README.md", "HuggingFace", "ModelKitDefaults.swift", "ChatDefaults.swift", "SpeechDefaults.swift",
                "VisionDefaults.swift", "SpeechProviderSelection.swift",
            ],
            sources: [
                "ModelManager.swift", "ModelRegistration.swift", "ModelArtifactContracts.swift",
                "ModelArtifactStore.swift", "ArtifactDownloadTransport.swift",
            ]),
        .target(
            name: "ModelKitEnergy", dependencies: ["ModelKit"],
            path: "MobileHarness/ModelKit/Speech/VAD/Energy",
            exclude: ["README.md"]),
        .target(
            name: "ModelKitAppleSpeech", dependencies: ["ModelKit"], path: "MobileHarness/ModelKit",
            exclude: [
                "README.md", "Language", "Vision", "Support/README.md", "Support/Core", "Support/Backends",
                "Support/Management", "Support/Speech/README.md", "Support/Speech/Apple/README.md", "Speech/README.md",
                "Speech/ASR/README.md", "Speech/TTS/README.md", "Speech/ASR/Apple/README.md",
                "Speech/TTS/Apple/README.md", "Speech/ASR/SpeechRecognitionCapability.swift",
                "Speech/TTS/SpeechSynthesisCapability.swift", "Speech/TTS/Kokoro", "Speech/TTS/MossNano",
                "Speech/ASR/Nemotron", "Speech/VAD",
            ],
            sources: ["Speech/ASR/Apple", "Speech/TTS/Apple", "Support/Speech/Apple"]),
        .target(
            name: "ModelKitYOLOPose", dependencies: ["ModelKit", "ModelKitCoreML"],
            path: "MobileHarness/ModelKit/Vision/YOLO", exclude: ["README.md"]),
        .testTarget(
            name: "YOLOPoseTests",
            dependencies: ["ModelKit", "ModelKitYOLOPose", "ModelKitCoreML", "ModelKitRuntime"],
            exclude: ["README.md"]),
        .target(name: "ModelKitCoreML", path: "MobileHarness/ModelKit/Support/Backends/CoreML", exclude: ["README.md"]),
        .target(
            name: "ModelKitSilero", dependencies: ["ModelKit", "ModelKitCoreML"],
            path: "MobileHarness/ModelKit/Speech/VAD/Silero", exclude: ["README.md"]),
        .testTarget(
            name: "SileroTests",
            dependencies: [
                "ModelKit", "ModelKitSilero", "ModelKitNemotron", "ModelKitKokoro", "Agents", "PlatformKit",
            ], exclude: ["README.md"]),
        .target(
            name: "ModelKitCoreAI", path: "MobileHarness/ModelKit/Support/Backends/CoreAI", exclude: ["README.md"]),
        .target(
            name: "ModelKitNemotron",
            dependencies: ["ModelKit", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "MobileHarness/ModelKit/Speech/ASR/Nemotron", exclude: ["README.md"]),
        .testTarget(
            name: "EnergyVADTests", dependencies: ["ModelKit", "ModelKitEnergy"], exclude: ["README.md"]),
        .testTarget(
            name: "NemotronTests", dependencies: ["ModelKit", "ModelKitNemotron"],
            exclude: ["README.md"]),
        .target(
            name: "ModelKitMossNano", dependencies: ["ModelKit"],
            path: "MobileHarness/ModelKit/Speech/TTS/MossNano", exclude: ["README.md"]),
        .testTarget(
            name: "MossNanoTests", dependencies: ["ModelKit", "ModelKitMossNano"],
            exclude: ["README.md"]),
        .target(
            name: "ModelKitKokoro",
            dependencies: ["ModelKit", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "MobileHarness/ModelKit/Speech/TTS/Kokoro", exclude: ["README.md"]),
        .testTarget(
            name: "KokoroTests", dependencies: ["ModelKit", "ModelKitKokoro"], exclude: ["README.md"]),
        .target(
            name: "PlatformKit", dependencies: [], path: "MobileHarness/PlatformKit",
            exclude: [
                "README.md", "Audio/README.md", "Vision/README.md", "Core/README.md", "Connectivity/README.md",
                "Connectivity/NexArm/README.md",
            ]),
        .testTarget(
            name: "FunctionContractTests", dependencies: ["FunctionContracts"],
            path: "Tests/FunctionContractTests", exclude: ["README.md"]),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "Storage",
                "BehaviorAssembly", "AppWorkflows", "UI",
                "AgentCore", "Gateway", "Agents", "Actions", "FunctionContracts", "ExecutionRuntime", "CallRuntime",
                "ModelKit", "ModelKitOpenAI", "ModelKitRuntime",
                "StorageChat", "StorageAudio", "StorageTasks", "StorageMedia", "StorageDevices", "StorageSQLite",
                "PlatformKit",
            ],
            exclude: ["README.md"]),
        .target(
            name: "ModelKitGemma4",
            dependencies: [
                "ModelKit", .product(name: "CoreAILM", package: "coreai-models"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "MobileHarness/ModelKit/Language/LLM/Gemma4", exclude: ["README.md"]),
        .testTarget(
            name: "Gemma4Tests", dependencies: ["Storage", "ModelKit", "ModelKitGemma4"],
            exclude: ["README.md"]),
        .testTarget(
            name: "AgentModelEvaluationTests",
            dependencies: ["Storage", "AgentCore", "Agents", "ModelKit", "ModelKitGemma4"],
            exclude: ["README.md"], resources: [.copy("Scenarios")]),
        .testTarget(
            name: "ModelKitDefaultsTests",
            dependencies: ["ModelKit", "ModelKitRuntime", "ModelKitDefaults"],
            exclude: ["README.md"]),
        .testTarget(name: "ModelKitTests", dependencies: ["ModelKit"], exclude: ["README.md"]),
        .testTarget(
            name: "ModelKitRuntimeTests", dependencies: ["ModelKit", "ModelKitRuntime"],
            exclude: ["README.md"]),
        .testTarget(
            name: "ModelKitAppleSpeechTests", dependencies: ["ModelKit", "ModelKitAppleSpeech"],
            exclude: ["README.md"]),
    ],
    swiftLanguageModes: [.v6]
)
