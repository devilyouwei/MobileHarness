# Application Boundary Adapters

## Summary

Converts native, model, function and storage contracts into injected App endpoints and independent UI values.

## Ownership and boundaries

Adapters translate and validate boundary values; they do not choose business operations, register providers or own scheduling queues. RuntimePresentation binds whole endpoints weakly and rejects overlap, missing owners and stale scopes.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 Functions[Actions capabilities] -->|FunctionInput| Adapters
 Adapters -->|Authorized endpoint| Lifecycle[App lifecycle and workflows]
 PlatformKit -->|Native preview| Adapters
 ModelKit -->|Current binding and resource facts| Adapters
 Storage -->|Documents and artifact files| Adapters
 Adapters -->|UI-owned values and content| UI
```

## Interface map

| Source | Responsibility |
| --- | --- |
| RuntimePresentation.swift | Typed presentation, speech, listening, camera and navigation capability forwarding; real producer/root-or-task authorization |
| MediaInputAdapter.swift | Host source/deadline/capture metadata; generic AgentCore media transport |
| CameraPreviewAdapter.swift / EyeExpression.swift | Native preview crop/rotation/mirroring and exhaustive expression conversion |
| CurrentChatCapability.swift | Resolve current ModelManager binding per request and forward provider support |
| ModelArtifactStorageAdapter.swift | Atomic task snapshots, receipts, confined artifact paths and file safety |
| SettingsModelResourcesAdapter.swift | Neutral inventory/preferences to revision-fenced UI values and localized failures |
| SettingsProviderAdapter.swift / SettingsCredentialAdapter.swift | Native SDK barriers, discovery and raw Keychain primitives; credential-free error adaptation |
| NexArmBehaviorAdapter.swift | Invocation-private reports, inherited permits and continuous-worker provenance |
| HistoryAgentAdapter.swift | Producing-role generation preview, including authorized communication catalog |
| SpeechFailurePresentation.swift | Known producer/storage failure wording after cleanup; original cause retained |

## Media and endpoint rules

Microphone inputs have a 60-second deadline; camera inputs have a one-second deadline. Each new input is its own causal root. Native rate/layout/capture instants are transported; perception Agents own conversion to ModelKit inputs. Camera preview uses resizeAspectFill and UI-owned projection values.

Camera effects require actual Photographer; listening requires actual SpeechPerception/root session; conversational navigation requires actual ApplicationControl/root-or-active-task identity. Local frontend methods use UI state directly. Missing or stale bindings fail rather than discarding effects.

## Resource and provider adaptation

Inventory adapters return neutral facts; Actions computes installation eligibility and grouping. Snapshots, operation errors and preference notices have independent revision/session commitment rules. Stable sorted-key fingerprints are bounded; unchanged binding tuples are cached only after successful application.

Receipts validate identity/revision, normalized confined relative paths, required files and exact sizes. Repair is limited to the exact former seven-hex staging-prefix form after validation. Different revisions fail as incompatible. Transfer records use atomic after-first-unlock storage; bookkeeping warnings remain distinct from successful artifact publication.

Keychain adapters expose raw operations and existing accessibility identifiers. Actions owns schema, migration and replacement order. Provider failureCode, HTTP status and configuration errors are mapped without credential-bearing SDK text. Cellular permission normalizes to true subject to OS permission; voice preferences remain independent.

## Reports and previews

NexArm reports are invocation-private and preserve every child outcome plus later exceptions. Continuous failures are separate execution diagnostics and do not rewrite completed Tool receipts or Bluetooth state. Speech errors are localized only after playback cleanup.

History preview combines the producing role's effective function and communication catalogs and shared segmentation. It parses the stored complete response string and rejected calls without executing them or claiming task delivery.

✅ Narrow typed adaptation, owner validation and neutral failure propagation are implemented.

## Related design

[Parent design](../README.md)

## Skill/task-mode contract

✅ History preview uses the persisted per-request catalog, including exact native schema, instead of current configuration. Missing catalogs fail preview explicitly. Camera/UI execution accepts authorized Assistant scopes as well as fixed deterministic owner scopes.

✅ 固定 Task 控制复用同一 Action：App 验证 Assistant/root-session；worker 仅在没有当前 worker、队列和接纳操作时接受无 decisionID 的可信控制。模型控制仍要求当前 input/session/round。固定终态在空闲清理条件下提交，不启动模型。

✅ SpeechFailurePresentation 删除不存在的 Agent 合成/缓存超时分类；超时展示来自 ActionResult 的真实函数结果，网络失败保留底层来源。

## Action timeout contract (2026-10-12)

✅ NexArmBehaviorAdapter 删除包裹单个 gesture 的冗余 ActionComposition，直接记录 invocation 私有报告；避免新默认叶子 30 秒覆盖有限动作动态总预算。


✅ Implemented: EyeExpression.swift maps Actions.closed to UI.closed; App endpoints reject nonclosed finite expression performances while no voice session is active. Persistent expression acceptance remains separate from resting visual state.


✅ Implemented: RuntimePresentation forwards validated UIFeedbackCapability and listening feedback parameters to the bound VoiceOutputHandling owner; missing bindings and invalid session/source reject. It owns no native player/generator or second composition.

## 历史记录收敛（2026-10-13）

✅ 已实现：HistoryAgentAdapter.preview 只使用 Assistant 当轮持久化目录；缺失或无效目录明确返回预览失败。删除角色选择与旧文本回退，不执行历史调用。

❌ 历史记录页面板块重新设计及原生 UI/真机验收。


✅ Implemented (2026-10-13): UI.Notice.showNotice/dismissNotice and UI.Light.updateLight are canonical presentation Actions for trusted business calls, currently registered by no Skill. Neutral Actions values cross RuntimePresentation into root-owned HomeEffectsWorkflow, which retains one replaceable notice expiry and one light expiry, UUID-fenced cleanup, and explicit stop. Notices remain separate from factual ExecutionIssue history; actual upper-layer errors have display priority and Action failures remain panel-only. Decorative light accepts normalized origin, initial opacity/intensity and duration; it never changes consent, microphone or eyes. Native renderer separates light generations from listening eye generations and preserves existing exit fade. RuntimePresentation adapts Action requests into UI-owned values; AppPresentationWorkflow keeps its existing UI/AgentCore/FunctionContracts boundary. No UI capability/business dependencies or new directories.

✅ Native build reconciled: UI values for Notice/Light use explicit Actions.PoseOverlay qualification at the neutral pose boundary, preserving the existing protocol signatures.


✅ Implemented (2026-10-13 caption/error lifecycle): mask bottom ASR and reply/status immediately while a notice is visible, restore retained text after dismissal, and preserve pinned Task/promoted ASR layout. Consent-off clears both captions; root HomeEffectsWorkflow owns one ID/text-fenced350ms reply fade/removal task, cancelled by new text/turn/off/shutdown, scheduled only after reply-policy/playback/native-resume barriers. Agent errors stay in factual root failure notices, not persistent voiceStatus copies. App root contexts explicitly choose afterFirstUnlock file protection, including their directory; repository persistent factory accepts protection while its SDK default remains whileUnlocked. This mitigates lock-boundary writes, without claiming the screenshot proves that cause or hiding other storage failures.

✅ VoiceOutputHandling.show is async; terminal cancellation/Agent failure joins matching input audio cleanup before output transport completes. RuntimePresentation forwards this lifecycle acknowledgment without admitting inference.

✅ 已实现：HistoryAgentAdapter.preview 不再遍历 delta 分片，只向临时 GenerationTrace 提交一次完整 response；预览不执行函数，不声称复现历史分片到达时间。





## SQLite records and runtime identity

✅ Implemented: technical identities are opaque UUID strings; committed business entities use dialog/message/task/media/device SQLite IDs. Consumers use Storage repositories while preserving ownership, cancellation and independent foundation boundaries. Complete messages, including each ReACT message, persist at termination; delta fragments do not persist. The custom allocator and replaced file/index implementation are removed. See the project SQLite business-record plan.


✅ Configuration preservation: ModelArtifactStorageAdapter uses the original Models/transfers.json. UUID and String generations share the same JSON string representation, so no transfer-schema migration or alternate numeric file is required. Installed receipts and model directories remain unchanged.
