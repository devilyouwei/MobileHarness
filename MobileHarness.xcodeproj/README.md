# Xcode Application Project

Purpose: build/sign the iOS application host and maintain physical-device, simulator and explicit model-validation schemes. Design goals: one source owner per target, matching navigation paths and no duplicate package compilation in App.

## Source ownership

- ✅ 验证与历史文档分别归入 docs/validation 和 docs/history；八个文档导航引用已同步，编译成员与资源构建设置保持原有配置。
- ✅ 需求文档归入 docs/requirements；Xcode 中 Photographer 提案引用指向新位置，仅调整文档导航路径，编译成员保持原有配置。
- ✅ MobileHarness and MobileHarnessSimulator compile App/MobileHarnessApp.swift, Composition, Lifecycle and Adapters.
- ✅ The root HarnessKit product supplies shared runtime modules, the independent UI target and AppWorkflows. Xcode navigates these sources without adding them to either App Sources phase. Model SDK adapters remain separate package targets.
- ✅ UI owns iOS pages/components and portable presentation state/operation interfaces. AppWorkflows owns history, configuration and explicit speech/chat diagnostics. Native preview/image/value adapters compile with App.
- ✅ CurrentChatCapability is compiled only by ModelKitRuntime; its navigator reference does not add it to App Sources. ChatDiagnosticWorkflow is package-owned navigation only. VoiceSessionCoordinator, VisionSession, ApplicationRuntime and UI component file references match their current responsibilities.
- ✅ Shared configuration, entitlements and privacy declarations retain their existing values. Local signing remains in ignored Config/Local.xcconfig.
- ✅ Platform input/output file lists stage only the shared source catalog/license notices on both device and simulator. Physical inference uses sandbox-installed Nemotron, Gemma4, Silero, YOLO and MOSS; Kokoro is unregistered. Simulator local models report unavailable; explicitly configured cloud chat remains supported.

NexArmAimCommand 的导航引用指向 Actions/Support；文件由现有 Actions SwiftPM target 唯一编译。

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

✅ Storage/Database/Chat now owns the ConversationHistory.swift reference and README. SwiftPM compiles StorageChat separately; no duplicate App Sources membership is introduced.

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

✅ Navigation includes Actions/Support/Contracts and Gateway runtime/protocol groups, Gateway translation/scheduling context and App workflow adapters. SwiftPM remains the single source compilation map.

✅ Photographer navigation and JSON are retained; SwiftPM owns compilation of Robot Tools and Action-side aim support.

✅ Scheme cleanup refreshes the generated embedded Agents bundle on incremental builds. Resource declarations remain in Package.swift; the final app is verified for every Agent config.

## Local model resources — current contract

✅ Both App source phases include the new Storage/settings adapters. Navigation references the new Management/Storage/Settings source files; package-owned sources still compile only through existing root targets. Model staging inputs/outputs are metadata-only for device and simulator.

❌ Full device/background acceptance and remaining enhancement items are tracked in [Management](../MobileHarness/ModelKit/Support/Management/README.md). The independent ModelKitHub target is included in HarnessKit; App entry and composition inject it. HF persisted native background transfer is implemented; OS/server behavior and full iPhone acceptance remain conditional.

✅ Models navigator references now show the shared catalog and separate Nemotron Mac profile; removed Audio8/Silero development references are cleaned up. Metadata-only staging is unchanged. ❌ Full Xcode build acceptance remains pending.


✅ Nemotron navigator now includes FluidAudio/LocalNemotronEngine.swift; obsolete CoreAI-specific Nemotron model, mel, tokenizer, unavailable adapter and bundled mel resources were removed.

✅ Local chat configuration now targets Gemma 4 E2B CoreAI; Qwen/MLX production bindings are removed. ❌ Real-model/device acceptance is separate from compilation and contract tests.

❌ The iOS simulator SDK lacks CoreAI; the external CoreAILM target cannot build there. build-ios.sh currently stops on this limitation. Independent UI tests run on Mac; a separate simulator assembly remains outstanding.

✅ Both App source phases include SpeechFailurePresentation; shared Storage/Agent/UI helpers remain package-owned. ❌ Simulator CoreAI availability and physical acceptance remain separate.

✅ ADR0151: file references for former Tools sources now point into Actions, matching the shared package's single source ownership. The legacy navigator group is labeled ToolCall Entries; Swift package targets determine compilation.
✅ Compatibility import targets have been removed. ❌ Physical acceptance remains separate work.

✅ ADR0152: production registers one six-domain CapabilityModules catalog, with unified UI/NexArm ownership and unchanged call paths/permissions. Registry projections preserve existing execution policy; regression coverage checks expression and gaze through the same UI catalog. ✅ Definitions are unified and compatibility targets removed.

✅ ADR0154 implements cohesive module entry files with one copy of each function and unchanged protocol behavior. File ownership is checked explicitly. ✅ Three-field path/configuration/registration migration is implemented.

✅ ADR0159 unifies @Action metadata and invocation contracts; all business and injected endpoints receive standard FunctionInput/ActionExecutionContext. Three-level ownership, existing availability/resources/deadlines and independent Agent grants are preserved.

✅ ADR0160: editor references include callable function/binding/failure contracts and grouped host profiles. The retired native arguments reference is removed; package targets continue to compile shared sources once. ❌ Physical acceptance remains separate.

## Gateway execution migration — ADR0161

✅ Navigator references now match Actions/Support/Contracts, Gateway/Runtime and Gateway/Output/Registration and Protocols. Package targets independently compile FunctionContracts, ExecutionRuntime and CallRuntime; shared sources are compiled once. Business endpoints use FunctionInput without Channel or calling protocol. ❌ Simulator CoreAI availability and physical acceptance remain separate.

✅ Actions navigator follows all six physical domain trees and shared Support (Contracts, ActionMacro and CapabilityModules); the obsolete ToolCall Entries/runtime group is removed. Gateway runtime and protocol groups are attached under their owning directories.

## ModelKit Support ownership

✅ The ModelKit navigator mirrors Support/Core, Backends, Management and Speech plus provider-owned engine sources. SwiftPM remains the sole shared-source compiler; no App Sources memberships or signing settings changed.

✅ CoreBoundaryTests and RuntimeBoundaryTests are navigation-only references. Core/management state ownership changed within existing source files; package ownership and App source memberships are preserved.


✅ Implemented: UI packages Components/ListeningHalo.metal via SwiftPM resource processing, producing its own default shader library; App imports the existing UI product. Shader resource compilation requires full Xcode and its installed Metal toolchain; use the matching DEVELOPER_DIR when the default xcode-select still points to Command Line Tools. No new target/dependency/directory or signing changes.


✅ Implemented: AppSpeechPlayback adds existing Actions and ExecutionRuntime products for child composition; new Swift files remain in existing package-owned directories. No source signing changes or new directories.


✅ App and simulator configurations use Config/AppInfo.plist to opt into ProMotion with public CADisableMinimumFrameDurationOnPhone; final bundle verification confirms the Boolean value. Native renderer requests device-supported high refresh for transitions, 60 Hz for settled flow, and pauses when off; requested FPS is not a guaranteed physical acceptance result.

✅ Implemented ProMotion packaging: Config/AppInfo.plist explicitly supplies CADisableMinimumFrameDurationOnPhone=true to both App targets. Generated standard/permission metadata remains enabled; remove the ineffective custom INFOPLIST_KEY setting and verify the final signed plist, not only build settings. No local signing edits.

✅ Shared Actions file references are grouped under Support, with Contracts as its own child and macro/catalog utilities directly under Support. SwiftPM remains the only compiler of these shared sources.


## Prefix-number identity migration

Implemented: business IDs are allocated by Storage; Foundation libraries use native UUID tokens and accept opaque caller IDs without project dependencies. Identity is no longer a package target. See [identity design](../docs/completed/Prefix-Numeric-ID-Plan.md).

## SQLite records migration

✅ StorageSQLite compiles GRDB.swift 7.11.1 privately through a separate adapter target; common Storage/domain consumers have no GRDB dependency. The lockfile pins it and App owns records.sqlite initialization. New internal Storage directories/targets implement approved ownership boundaries; signing is unchanged. Required simulator/device build outcomes are recorded separately in docs/validation/Validation-History.md.

✅ Storage repository refactor: HarnessKit/App composition links the explicit StorageSQLite adapter product and existing domain targets; no new first-level application module or signing change.

Storage 四类容器通过本地 HarnessKit 产品暴露，AppStorage 单独编译注册源码；App Sources 不重复包含 ApplicationContainer。FactoryKit 3.4.1 由 SwiftPM 固定解析，存储目录引用与新路径一致。

## 公开 State 边界

✅ StorageState 仅承载公开事实；边界检查禁止完整 AgentContext 注册，校验 Skill schema v2/useState。沿用现有源码归属及目标，ActionBindings 显式依赖 StorageState。

[公开 State 契约](../MobileHarness/Storage/State/README.md)

✅ Platform 容器、设备输入和同帧渲染文件更新导航引用；移除已删除的媒体适配、VisionSession 与原生预览引用，SwiftPM 仍唯一编译这些源码。

## UI 容器与相机能力注入

✅ 导航加入 UIContainer、UICameraContainer 和 CameraCapturing，均只由现有 SwiftPM 目标编译；不新增目录、目标或本地签名配置。

## Container diagnostics source ownership

Implemented: ContainerFailureChannel.swift is a Gateway SwiftPM source and navigator reference only, never duplicated into the App executable.

## ApplicationControl 异常展示

✅ 已实现：内部 RuntimeDiagnostics 函数由本地包 Actions 编译；不新增 Xcode 目标或目录，Foundation/UI 依赖边界不变。

## UI 全量容器化

✅ 应用级 UI 状态由八个子容器统一创建，消费者注入所需 Presenting 接口并提交 UI 自有值，不直接写字段。App 注册并管理同一 UI 根；原业务身份/版本校验、原生完成和基础库依赖边界保持。跨模块连接迁移仍是独立待办。

✅ UI 工程导航指向实际存在的归类文件，SwiftPM 保持唯一编译归属；没有重复 App Sources 成员，签名、target 与依赖边界保持。

✅ 共享存储错误由一个源文件编译，CurrentChatCapability 由 ModelKitRuntime 唯一编译；工程导航不添加重复 App Sources，target 与签名配置保持。
