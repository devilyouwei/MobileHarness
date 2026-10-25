// swift-tools-version: 6.4

import CompilerPluginSupport
import Foundation
import PackageDescription

let simulatorBuild = ProcessInfo.processInfo.environment["MOBILEHARNESS_BUILD_VARIANT"] == "simulator"
let localChatDependencies: [Target.Dependency] = simulatorBuild ? [] : ["ModelKitGemma4"]

let package = Package(
    name: "HarnessKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(
            name: "HarnessKit",
            targets: [
                "AgentCore", "Gateway", "Agents", "Actions", "FunctionContracts", "ExecutionRuntime", "CallRuntime",
                "ModelKit",
                "Storage", "AppStorage", "StorageFiles", "StorageDatabase", "StorageCore",
                "StorageChat", "StorageCache", "StorageTasks", "StorageMedia", "StorageDevices",
                "StorageSQLite", "UI", "AppLifecycle",
                "ModelKitAppleSpeech", "ModelKitRuntime", "ModelKitDefaults", "ModelKitHub",
                "ModelKitSilero", "ModelKitNemotron", "ModelKitMossNano",
                "PlatformKit",
            ]),
        .library(name: "StorageCore", targets: ["StorageCore"]),
        .library(name: "StorageChat", targets: ["StorageChat"]),
        .library(name: "StorageCache", targets: ["StorageCache"]),
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
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "StorageFiles", targets: ["StorageFiles"]),
        .library(name: "StorageDatabase", targets: ["StorageDatabase"]),
        .library(name: "AppStorage", targets: ["AppStorage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/hmlongco/Factory", exact: "3.4.1"),
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
            name: "UI", dependencies: [], path: "MobileHarness/UI",
            exclude: [
                "README.md", "Camera/README.md", "Components/README.md", "Conversation/README.md",
                "Settings/README.md", "Diagnostics/README.md",
            ], resources: [.process("Components/ListeningHalo.metal")]),

        .target(
            name: "AppLifecycle", dependencies: [], path: "MobileHarness/App/Lifecycle",
            exclude: ["README.md", "ApplicationSystemDelegate.swift"], sources: ["ApplicationLifecycle.swift"]),
        .testTarget(
            name: "ModelKitHubTests",
            dependencies: [
                "ModelKitHub", "ModelKitRuntime", .product(name: "HuggingFace", package: "swift-huggingface"),
            ], exclude: ["README.md"]),
        .testTarget(name: "UITests", dependencies: ["UI"], exclude: ["README.md"]),
        .testTarget(
            name: "AppWorkflowTests",
            dependencies: [
                "StorageFiles",
                "StorageCore",
                "AppLifecycle", "Gateway", "Actions", "FunctionContracts",
                "ExecutionRuntime", "PlatformKit", "UI", "StorageChat", "ModelKit", "Agents",
            ],
            exclude: ["README.md"]),
        .target(
            name: "AgentCore", dependencies: ["FunctionContracts"], path: "MobileHarness/Agents/Support/Core",
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
            path: "MobileHarness/Actions/Support",
            exclude: [
                "ActionBinding.swift", "ActionBindingModule.swift", "ActionExecutor.swift", "ActionMacro.swift",
                "ActionRegistry.swift", "Contracts", "README.md", "ToolExecutor.swift", "ToolModule.swift",
                "ToolRegistry.swift",
            ],
            sources: [
                "FunctionExecutor.swift", "FunctionRegistry.swift", "ActionDeadline.swift",
                "CooperativeExecution.swift", "ActionComposition.swift",
            ]),
        .target(
            name: "CallRuntime", dependencies: ["FunctionContracts", "ExecutionRuntime"],
            path: "MobileHarness/Actions/Support",
            exclude: [
                "ActionComposition.swift", "ActionDeadline.swift", "ActionMacro.swift", "Contracts",
                "CooperativeExecution.swift", "FunctionExecutor.swift", "FunctionRegistry.swift", "README.md",
            ],
            sources: [
                "ActionBindingModule.swift", "ToolRegistry.swift", "ActionRegistry.swift", "ActionBinding.swift",
                "ToolModule.swift", "ActionExecutor.swift", "ToolExecutor.swift",
            ]),
        .target(
            name: "Gateway", dependencies: ["FunctionContracts"],
            path: "MobileHarness/Gateway",
            exclude: [
                "README.md", "Input/README.md", "Output/README.md", "Output/Scheduling/README.md",
                "Output/Dispatch/README.md", "Output/Resources/README.md", "Output/Results/README.md",
            ]),
        .target(
            name: "Actions",
            dependencies: [
                "BehaviorDefinitions", "CallRuntime", "ExecutionRuntime", "FunctionContracts", "ModelKit",
                "ModelKitDefaults", "ModelKitHub", "ModelKitOpenAI", "ModelKitRuntime", "PlatformKit", "StorageCache",
                "StorageChat", "StorageCore", "StorageDevices", "StorageFiles", "StorageMedia", "UI",
            ],
            path: "MobileHarness/Actions",
            exclude: [
                "Camera/README.md",
                "History/README.md",
                "NexArm/Connection/README.md",
                "NexArm/Motion/README.md",
                "NexArm/README.md",
                "NexArm/Support/README.md",
                "NexArm/Tracking/README.md",
                "README.md",
                "Speech/Detection/README.md",
                "Speech/Listening/README.md",
                "Speech/Playback/README.md",
                "Speech/README.md",
                "Speech/Support/README.md",
                "Support/README.md",
                "System/Device/README.md",
                "System/Diagnostics/README.md",
                "System/ModelResources/README.md",
                "System/Provider/README.md",
                "System/README.md",
                "System/Task/README.md",
                "UI/Conversation/README.md",
                "UI/Expression/README.md",
                "UI/Feedback/README.md",
                "UI/Navigation/README.md",
                "UI/Pose/README.md",
                "UI/README.md",
                "UI/Resources/README.md",
                "UI/Runtime/README.md",
                "UI/Support/README.md",
                "Support/Contracts",
                "Support/FunctionExecutor.swift",
                "Support/FunctionRegistry.swift",
                "Support/ActionDeadline.swift",
                "Support/CooperativeExecution.swift",
                "Support/ActionComposition.swift",
                "Support/ActionBindingModule.swift",
                "Support/ToolRegistry.swift",
                "Support/ActionRegistry.swift",
                "Support/ActionBinding.swift",
                "Support/ToolModule.swift",
                "Support/ActionExecutor.swift",
                "Support/ToolExecutor.swift",

            ]),
        .target(
            name: "Agents",
            dependencies: [
                "AgentCore", "FunctionContracts", "Gateway", "ModelKit",
                "ModelKitDefaults", "ModelKitHub", "ModelKitRuntime", "PlatformKit", "StorageCache", "StorageChat",
                "StorageCore", "StorageDevices", "StorageFiles", "StorageMedia", "StorageTasks", "UI",
            ],
            path: "MobileHarness",
            exclude: [
                "Actions",
                "Agents/ApplicationControl/README.md", "Agents/Assistant/README.md", "Agents/Memory/README.md",
                "Agents/Photographer/README.md", "Agents/README.md", "Agents/SpeechPerception/README.md",
                "Agents/SpeechSynthesis/README.md", "Agents/Support/Chat/README.md",
                "Agents/Support/Communication/README.md", "Agents/Support/Context/README.md", "Agents/Support/Core",
                "Agents/Support/Core/Capability/README.md", "Agents/Support/Core/Communication/README.md",
                "Agents/Support/Core/Generation/README.md", "Agents/Support/Core/Input/README.md",
                "Agents/Support/Core/Output/README.md", "Agents/Support/Core/README.md",
                "Agents/Support/Core/Runtime/README.md", "Agents/Support/README.md",
                "Agents/VisionPerception/README.md", "App", "Gateway", "ModelKit", "PlatformKit", "README.md",
                "Resources/Agents/README.md", "Resources/AppIconVariants", "Resources/Assets.xcassets",
                "Resources/Models", "Resources/PrivacyInfo.xcprivacy", "Resources/README.md", "Storage", "UI",
            ], sources: ["Agents"],
            resources: [.copy("Resources/Agents"), .copy("Resources/Skills"), .copy("Resources/Catalog.json")]),
        .target(
            name: "StorageCore", dependencies: [], path: "MobileHarness/Storage",
            exclude: [
                "README.md", "StorageContainer.swift", "Cache", "Files", "Database",
                "Support/README.md", "Support/Contracts/README.md", "Support/Memory/README.md",
            ], sources: ["StorageFailure.swift", "Support/Contracts", "Support/Memory"]),
        .target(
            name: "StorageCache", dependencies: ["StorageCore"], path: "MobileHarness/Storage/Cache",
            exclude: ["README.md", "Audio/README.md"]),
        .target(
            name: "StorageFiles", dependencies: ["StorageCore"], path: "MobileHarness/Storage/Files",
            exclude: ["README.md"]),
        .target(
            name: "StorageTasks", dependencies: ["StorageCore"], path: "MobileHarness/Storage/Database/Tasks",
            exclude: ["README.md"]),
        .target(
            name: "StorageChat", dependencies: ["StorageCore", "StorageTasks"],
            path: "MobileHarness/Storage/Database/Chat", exclude: ["README.md"]),
        .target(
            name: "StorageMedia", dependencies: ["StorageCore", "StorageFiles"],
            path: "MobileHarness/Storage/Database/Media", exclude: ["README.md"]),
        .target(
            name: "StorageDevices", dependencies: ["StorageCore"], path: "MobileHarness/Storage/Database/Devices",
            exclude: ["README.md"]),
        .target(
            name: "StorageDatabase",
            dependencies: ["StorageCore", "StorageChat", "StorageTasks", "StorageMedia", "StorageDevices"],
            path: "MobileHarness/Storage/Database",
            exclude: ["README.md", "Chat", "Tasks", "Media", "Devices", "SQLite"], sources: ["DatabaseStorage.swift"]),
        .target(
            name: "StorageSQLite",
            dependencies: [
                "StorageCore", "StorageDatabase", "StorageChat", "StorageTasks", "StorageMedia", "StorageDevices",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "MobileHarness/Storage/Database/SQLite", exclude: ["README.md"]),
        .target(
            name: "Storage",
            dependencies: ["StorageCore", "StorageCache", "StorageFiles", "StorageDatabase"],
            path: "MobileHarness/Storage",
            exclude: ["README.md", "StorageFailure.swift", "Cache", "Files", "Database", "Support"],
            sources: ["StorageContainer.swift"]),
        .target(
            name: "AppStorage",
            dependencies: [
                "Actions",
                "Storage", "StorageCore", "StorageCache", "StorageFiles", "StorageDatabase",
                "StorageSQLite", "PlatformKit", "UI", "Agents", "Gateway", "ModelKit", "ModelKitDefaults",
                .product(name: "FactoryKit", package: "Factory"),
            ],
            path: "MobileHarness/App/Composition",
            exclude: [
                "README.md", "AppComposition.swift", "ModuleRegistration.swift", "ServiceFactories.swift",
                "AgentResourceBindings.swift", "ActionServiceAdapters.swift", "ApplicationActionAssembly.swift",
                "ApplicationPresentation.swift",
            ],
            sources: ["ApplicationContainer.swift"]),
        .target(
            name: "ModelKit", dependencies: [], path: "MobileHarness/ModelKit",
            exclude: [
                "README.md", "ModelContainer.swift", "Language/README.md", "Language/JEV/README.md",
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
                "ModelKitMossNano", "ModelKitYOLOPose", "ModelKitOpenAI", "ModelKitAppleSpeech",
                "ModelKitEnergy",
            ] + localChatDependencies,
            path: "MobileHarness/ModelKit",
            exclude: [
                "README.md", "ModelFailure.swift", "Language", "Speech", "Vision",
                "Support/README.md", "Support/Core", "Support/Backends", "Support/Speech",
                "Support/Management/README.md", "Support/Management/HuggingFace",
                "Support/Management/ModelManager.swift", "Support/Management/ModelRegistration.swift",
                "Support/Management/ModelArtifactContracts.swift", "Support/Management/ModelArtifactStore.swift",
                "Support/Management/ArtifactDownloadTransport.swift",
            ],
            sources: [
                "ModelContainer.swift", "Support/Management/ChatDefaults.swift",
                "Support/Management/SpeechDefaults.swift",
                "Support/Management/VisionDefaults.swift", "Support/Management/SpeechProviderSelection.swift",
            ]),
        .target(
            name: "ModelKitRuntime", dependencies: ["ModelKit"],
            path: "MobileHarness/ModelKit/Support/Management",
            exclude: [
                "README.md", "HuggingFace", "ChatDefaults.swift", "SpeechDefaults.swift",
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
                "README.md", "ModelContainer.swift", "ModelFailure.swift", "Language", "Vision", "Support/README.md",
                "Support/Core", "Support/Backends",
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
                "StorageFiles", "Storage", "StorageDatabase", "AppStorage",
                "StorageCore",
                "AppLifecycle", "UI",
                "AgentCore", "Gateway", "Agents", "Actions", "FunctionContracts", "ExecutionRuntime", "CallRuntime",
                "ModelKit", "ModelKitOpenAI", "ModelKitRuntime",
                "StorageChat", "StorageCache", "StorageTasks", "StorageMedia", "StorageDevices", "StorageSQLite",
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
            name: "Gemma4Tests", dependencies: ["StorageCore", "ModelKit", "ModelKitGemma4"],
            exclude: ["README.md"]),
        .testTarget(
            name: "AgentModelEvaluationTests",
            dependencies: ["StorageCore", "AgentCore", "Agents", "ModelKit", "ModelKitGemma4"],
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
