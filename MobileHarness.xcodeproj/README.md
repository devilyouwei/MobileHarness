# Xcode Application Project

Purpose: build/sign the iOS application host and maintain physical-device, simulator and explicit model-validation schemes. Design goals: one source owner per target, matching navigation paths and no duplicate package compilation in App.

## Source ownership

- ✅ MobileHarness and MobileHarnessSimulator compile App/MobileHarnessApp.swift, Composition, Lifecycle and Adapters.
- ✅ The root HarnessKit product supplies shared runtime modules, the independent UI target and AppWorkflows. Xcode navigates these sources without adding them to either App Sources phase. Model SDK adapters remain separate package targets.
- ✅ UI owns iOS pages/components and portable presentation state/operation interfaces. AppWorkflows owns history, configuration and explicit speech/chat diagnostics. Native preview/image/value adapters compile with App.
- ✅ App source membership includes CurrentChatCapability; ChatDiagnosticWorkflow is package-owned navigation only. VoiceSessionCoordinator, VisionSession, ApplicationRuntime and UI component file references match their current responsibilities.
- ✅ Shared configuration, entitlements and privacy declarations retain their existing values. Local signing remains in ignored Config/Local.xcconfig.
- ✅ Platform input/output file lists govern local model staging. The physical profile uses Nemotron, Qwen3.5, Silero, YOLO and MOSS; legacy Kokoro is not packaged. Simulator local models report unavailable; explicitly configured cloud chat remains supported.

## Validation

✅ scripts/check.sh validates source/target boundaries, tests and project metadata. scripts/build-ios.sh builds the simulator App plus the ModelKitRuntime/Nemotron/Silero schemes. The MobileHarness scheme provides signed physical-device builds; installation and interaction acceptance are separate actions.

❌ Build success does not establish microphone, playback, live-provider, model protocol, latency or sustained thermal acceptance. Independent multi-window runtime ownership remains unimplemented.

✅ Action runtime stage 1 sources, scheduling errors and contract tests are referenced in the existing navigator groups. SwiftPM still compiles the shared source directories; no duplicate source or new target was added. ❌ Physical-device acceptance remains separate.
