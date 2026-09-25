# Xcode application project

Purpose: build and sign the iOS composition root and maintain the existing UI-only simulator and model validation schemes.

✅ Physical MobileHarness links ModelKitQwen35 from the optional local model package; model sources remain in their package targets rather than being duplicated in the App target.
✅ Both app targets include the Debug-only Qwen/ASR validation view; normal launches retain conversation UI.
✅ Platform file lists govern model resource staging. The simulator retains explicit unavailable ASR and chat behavior.
❌ A successful build does not establish live microphone, sustained thermal, or model protocol quality acceptance.

✅ The navigator references FunctionTokenParser.swift and FunctionTokenParserTests.swift; shared sources remain compiled by SwiftPM.

✅ The navigator references ActionCall.swift; AgentCore owns the shared resolved Action invocation type.

✅ The App bundles Nemotron, Qwen3.5-2B, Silero and diagnostic Kokoro from flat local directories. Audio8/ONNX targets and runtime manifest references are absent. Pre-build cleanup prevents stale generated model files from surviving a model selection change.

✅ Shared source navigation uses OperationAdmission. Model acquisition and lifecycle composition belong to ModelKitRuntime; no resolver or convenience capability bundle is required.

✅ The optional language product is ModelKitQwen35; native CoreAI graph targets support Nemotron and Kokoro.

✅ Both App targets consume the single root Swift package. The physical target explicitly links its ModelKitQwen35 product; ModelKit has no separate package reference. Management and Backends navigation follow the physical source directories.

✅ AudioFrame.swift is part of ModelKit/Core. Core is the home for shared audio and future image/video contracts; platform I/O and model-specific processing remain separate. ❌ Image/video types are not implemented until needed.

✅ App resolves ModelKitDefaults through the root project product; default assembly selects providers internally. No App source directly imports model adapters.
