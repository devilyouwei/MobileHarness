// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DecisionBenchmarks",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(
            url: "https://github.com/john-rocky/coreai-models",
            revision: "3dc4ceb5ec9d2e488b9c995d53a415b9e22fe7ba")
    ],
    targets: [
        .executableTarget(
            name: "DecisionDecoder",
            dependencies: [.product(name: "CoreAILM", package: "coreai-models")],
            path: ".",
            exclude: ["README.md", "benchmark.py", "fixtures.json", "models.json", "requirements.txt"],
            sources: ["DecisionDecoder.swift"])
    ])
