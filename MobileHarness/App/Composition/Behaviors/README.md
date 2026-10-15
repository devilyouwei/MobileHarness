# Behavior Assembly

## Summary

Builds one canonical function catalog and projects explicit Action and Tool registration views.

## Ownership and boundaries

The BehaviorAssembly target depends on Actions, FunctionContracts, ExecutionRuntime and CallRuntime. It does not import AgentCore or select Agent permissions. Host bindings choose protocol, scheduling and fixed-caller result delivery; Actions owns implementation metadata.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 Host[App composition] -->|Injected capabilities| Assembly[BehaviorAssembly]
 Actions -->|CapabilityModules and definitions| Assembly
 Assembly -->|Frozen functions and protocol views| Runtime[Gateway registration and execution]
 Runtime -->|FunctionInput| Functions[Registered handlers]
```

## Catalog and protocol binding

BehaviorAssembly.swift validates the catalog, freezes FunctionRegistry once and shares it with both views. Duplicate addresses, missing implementations and unknown module profiles fail explicitly. Canonical resource and execution budgets come from the same definition.

BehaviorProtocolBindings.swift groups scheduling profiles by business module. ActionCall uses Channel/wait ordering; ToolCall uses direct returning execution. Both invoke the same FunctionInput handler. ReACT is derived by the Agent from the actual completion value/report or failure.

Camera functions have fixed Tool and scheduled Action bindings; Photographer uses fixed Camera transactions; Assistant photography Skills expose the scheduled Camera Actions. System.Device.readEnvironment has both projections; Assistant exposes its Action only. UI.Navigation.open supports Agent Action execution while touch navigation calls the shared UI method locally. Speech.Listening.update is internal to SpeechPerception. Directed model communication is an authorized send Action supplied by the Agent layer, never an automatically added Tool.

## Validation and failure

Required capability injection has no no-op production default. Startup coverage checks the effective permissions against registered handlers before producers start. Agent aliases, internal grants and communication rights remain in role configuration/code. This directory owns no inference loop, native queue or task lifetime.

Frozen shared function storage, explicit projections and implementation coverage are implemented.

## Related design

[Parent design](../README.md)

Agent.Task controls register as Control Channel Action calls returning committed state. Start/load/release supply business output for continuation; terminal controls join cleanup, close their Task and release its owned Skill roots.

## Skill/task-mode contract

TaskControlModule registers canonical loadSkills/releaseSkills/startTask/finishTask/cancelTask functions. RuntimePresentation injects the actual Assistant control endpoint; canonical implementations are shared by fixed and Action calls.

## Channel-owned Action ordering

Action metadata has no serialization key. [ChannelScheduler](../../../Gateway/Output/Scheduling/README.md) owns task-local FIFO/wait ordering; ResourceCoordinator rejects unconfigured conflicts without a queue and preserves explicitly configured joined takeover.

## Task controls through Action Calls

BasicSkill 的五个 Task/Skill 控制函数使用 Control Channel Action Call；App 通过 ChannelScheduler 返回已提交状态。startTask/loadSkills/releaseSkills 返回的已提交业务状态在结果屏障后重建目录并 ReACT，finishTask/cancelTask 加入回复及清理屏障后回收所属 Task 的非基础根 Skill，无关近期项按其原作用域保留。新目录仅影响后续请求，不允许加载轮提前调用新函数。可信固定调用复用同一实现。

## Result-driven ReACT

BehaviorProtocolBindings 配置协议，BehaviorAssembly 配置执行路径和固定调用结果投递；模型 ReACT 由实际业务结果决定。

ApplicationControl操作型绑定：Device.control、ModelResources.download/cancel增加Action协议投影并保留固定调用Tool投影，均复用原canonical handler和返回语义。模型当前目录只开放Skill声明的一种类型，宿主双协议不导致模型重复注册。

UI.Feedback maps to scheduled Action bindings alongside UI.Expression/Speech.Playback. Canonical child definitions are reused inside the parent listening composition; budgets and report semantics are inherited rather than duplicated by private playback code.

UI.Notice.showNotice/dismissNotice 与 UI.Light.updateLight 使用 canonical 业务绑定，当前没有 Skill 暴露；能力缺失必须明确失败。原生展示所有者见 [Presentation](../../Workflows/Presentation/README.md)。

## Host protocol binding matrix

| Canonical group | Host projections | Direct result / execution |
| --- | --- | --- |
| Camera.Capture; UI.Navigation; System.Device.readEnvironment/control; System.ModelResources.download/cancel | Action + Tool | direct / returning |
| Agent.Task | Action | direct / returning |
| UI.Caption.print/beginReplyTurn | Action + Tool | direct / completion-only 默认 |
| UI.Expression/Feedback/Notice/Light; Speech.Playback/Listening; NexArm.Motion/Gesture | Action | 默认 scheduled 绑定 |
| History.Conversation; System.Runtime/Provider; remaining System.ModelResources/Device; UI.ResourcePresentation | Tool | direct / returning |
| UI.Gaze/VoiceState/Pose/HistoryPresentation; remaining UI.Caption; NexArm.Tracking | Tool | direct / completion-only 默认 |

BehaviorProtocolBindings.bind 按精确地址优先匹配，再选择 module profile；未知模块拒绝。表描述宿主实现投影，不决定当前 Skill 向模型开放的协议类型，也不改变内在资源、预算或业务完成语义。

## 待实现

- Dynamic function discovery and registry hot reload are not implemented.
