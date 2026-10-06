# Xcode Application Project

Purpose: build/sign the iOS application host and maintain physical-device, simulator and explicit model-validation schemes. Design goals: one source owner per target, matching navigation paths and no duplicate package compilation in App.

## Source ownership

- ✅ MobileHarness and MobileHarnessSimulator compile App/MobileHarnessApp.swift, Composition, Lifecycle and Adapters.
- ✅ The root HarnessKit product supplies shared runtime modules, the independent UI target and AppWorkflows. Xcode navigates these sources without adding them to either App Sources phase. Model SDK adapters remain separate package targets.
- ✅ UI owns iOS pages/components and portable presentation state/operation interfaces. AppWorkflows owns history, configuration and explicit speech/chat diagnostics. Native preview/image/value adapters compile with App.
- ✅ App source membership includes CurrentChatCapability; ChatDiagnosticWorkflow is package-owned navigation only. VoiceSessionCoordinator, VisionSession, ApplicationRuntime and UI component file references match their current responsibilities.
- ✅ Shared configuration, entitlements and privacy declarations retain their existing values. Local signing remains in ignored Config/Local.xcconfig.
- ✅ Platform input/output file lists stage only the shared source catalog/license notices on both device and simulator. Physical inference uses sandbox-installed Nemotron, Qwen3.5, Silero, YOLO and MOSS; Kokoro is unregistered. Simulator local models report unavailable; explicitly configured cloud chat remains supported.

## Validation

✅ scripts/check.sh validates source/target boundaries, tests and project metadata. scripts/build-ios.sh builds the simulator App plus the ModelKitRuntime/Nemotron/Silero schemes. The MobileHarness scheme provides signed physical-device builds; installation and interaction acceptance are separate actions.

❌ Build success does not establish microphone, playback, live-provider, model protocol, latency or sustained thermal acceptance. Independent multi-window runtime ownership remains unimplemented.

✅ Action runtime stage 1 sources, scheduling errors and contract tests are referenced in the existing navigator groups. SwiftPM still compiles the shared source directories; no duplicate source or new target was added. ❌ Physical-device acceptance remains separate.

## Action runtime stage 2

✅ Stage 2 shared result/lease/inbox, Gateway Results/Resources and integration test files appear in the navigator. SwiftPM retains sole compilation ownership of these shared sources. ❌ No new physical-device acceptance is implied.

## Domain-owned behavior assembly

✅ Action/Tool module catalogs, capability protocols, ToolDefinition and BehaviorAssembly sources/tests appear in the navigator. BehaviorAssembly compiles once through SwiftPM and is exported by HarnessKit; its source is not added to App Sources. ❌ No additional signing/device acceptance changes.

## Action implementation audit

✅ Canonical UIActions/SpeechActions namespaces, audioID-only SpeechActions.swift and ActionAuthoringTests are navigation-only shared package sources; no duplicate App compilation.

## Storage domain organization

✅ Storage/Chat now owns the ConversationHistory.swift reference and README. SwiftPM compiles StorageChat separately; no duplicate App Sources membership is introduced.

✅ Photographer, Robot.aim and the NexArm frame sources are navigator references. SwiftPM compiles them; they are not added to App Sources.

❌ Image/video/semantic-memory stores remain planned; this migration adds no storage behavior.

✅ NexArm Action, PlatformKit connectivity and diagnostic test sources are navigation-only references. SwiftPM owns compilation; the macOS serial implementation is excluded on iOS by conditional compilation. ❌ No iPhone robot binding is enabled.

✅ NexArmActions.swift is navigation-only and compiled by the existing Actions package target; ❌ no duplicate App compilation or iPhone USB binding.

✅ App configurations include NSBluetoothAlwaysUsageDescription; NexArmBluetooth, BluetoothWorkflow, settings UI and tests are SwiftPM-owned navigation references. No Bluetooth background mode is enabled. ❌ Simulator build success does not prove a Bluetooth radio connection.

## NexArm entertainment skills (2026-09-30)

✅ Navigator groups mirror consolidated domain entries and their Support subdirectories, including grouped registration and type files. Swift package targets compile the shared sources; no duplicate source copies or signing settings added. ❌ Physical gesture acceptance remains separate from builds.

✅ Actions navigation is rebuilt from its actual entry/Support/Runtime files, removing obsolete per-verb and migrated UI references. All remain SwiftPM-owned, without App Sources membership.

✅ Removed the unused NexArmDiagnostics navigation reference together with its Action entry; production action/support sources retain their existing package ownership.

✅ Tools navigator mirrors the Runtime/domain/Support layout, including all grouped callable entries and support files. Shared Tools sources continue compiling through SwiftPM only. ❌ This navigation update adds no App source build memberships.

✅ ADR0093 updates the NexArm controller navigator reference to Actions/NexArm/Support. SwiftPM remains the source/target authority for the migrated shared implementation.

✅ The NexArm jog-planner navigator entry now belongs to Actions/NexArm/Support; shared implementation files continue to compile through their SwiftPM targets.

✅ The local package builds BehaviorDefinitions as a host compiler macro plugin for Action/Tool metadata; it is not an iOS runtime device dependency. NexArm profile/budget policy remains in the Actions target.

✅ Navigation no longer references unused permission/transport placeholders. Historical NexArm diagnostics are listed under root IntegrationTests; production compilation remains SwiftPM-owned.

✅ Navigation includes Actions/Runtime/Contracts and Tools/Runtime/Contracts, Gateway translation/scheduling context and App workflow adapters. SwiftPM remains the single source compilation map.

✅ Photographer navigation and JSON are retained; SwiftPM owns compilation of Robot Tools and Action-side aim support.

✅ Scheme cleanup refreshes the generated embedded Agents bundle on incremental builds. Resource declarations remain in Package.swift; the final app is verified for every Agent config.

## Local model resources — current contract

✅ Both App source phases include the new Storage/settings adapters. Navigation references the new Management/Storage/Settings source files; package-owned sources still compile only through existing root targets. Model staging inputs/outputs are metadata-only for device and simulator.

❌ Full device/background acceptance and remaining enhancement items are tracked in [Management](../MobileHarness/ModelKit/Management/README.md). The independent ModelKitHub target is included in HarnessKit; App entry and composition inject it. HF durable background transfer is not implemented.

✅ Models navigator references now show the shared catalog and separate Nemotron Mac profile; removed Audio8/Silero development references are cleaned up. Metadata-only staging is unchanged. ❌ Full Xcode build acceptance remains pending.


✅ Nemotron navigator now includes FluidAudio/LocalNemotronEngine.swift; obsolete CoreAI-specific Nemotron model, mel, tokenizer, unavailable adapter and bundled mel resources were removed.

✅ Local chat configuration now targets Gemma 4 E2B CoreAI; Qwen/MLX production bindings are removed. ❌ Real-model/device acceptance is separate from compilation and contract tests.

❌ The iOS simulator SDK lacks CoreAI; the external CoreAILM target cannot build there. build-ios.sh currently stops on this limitation. Independent UI tests run on Mac; a separate simulator assembly remains outstanding.

✅ Both App source phases include SpeechFailurePresentation; shared Storage/Agent/UI helpers remain package-owned. ❌ Simulator CoreAI availability and physical acceptance remain separate.

✅ ADR0151: file references for former Tools sources now point into Actions, matching the shared package's single source ownership. The legacy navigator group is labeled ToolCall Entries; Swift package targets determine compilation.
❌ Remove compatibility import targets after consumer migration; scheduled ToolCall and physical acceptance remain separate work.

✅ ADR0152: production registers one six-domain CapabilityModules catalog, with unified UI/NexArm ownership and unchanged call paths/permissions. Registry projections preserve existing execution policy; regression coverage checks expression and gaze through the same UI catalog. ❌ Unified call definitions and compatibility removal remain pending.

✅ ADR0154 implements cohesive module entry files with one copy of each function and unchanged protocol behavior. File ownership is checked explicitly. ❌ Three-field path/configuration/registration migration remains outstanding.
