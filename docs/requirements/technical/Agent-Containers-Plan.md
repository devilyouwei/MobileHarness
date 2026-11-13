# Agent containers

## Requirements

One AgentContainer exposes stable Assistant, ApplicationControl, Memory, Photographer, SpeechPerception, SpeechSynthesis and VisionPerception containers. Retain existing role policy, Gateway authorization and Actions execution ownership. No new directories or compilation targets.

## Current contract owners

- [Agents](../../../MobileHarness/Agents/README.md#agent-container): root API, seven stable role capabilities, ownership and module failure contract.
- [Support](../../../MobileHarness/Agents/Support/README.md#lifetime-bounds-and-failures): lifecycle algorithm, bounds, cancellation and cleanup.
- [App composition](../../../MobileHarness/App/Composition/README.md): cached root, dependency graph and presentation wiring.

## Implementation

- Implemented: role containers own context/session lifetime, registration, subscriptions, output and cleanup. Runtime only wires shared facilities.
- Implemented: root construction is inert. Start/stop coalesce; invalidate synchronously fences admission. Foreground transitions join cleanup. Stop is terminal. Partial startup rolls back.
- Implemented: AgentFailure retains original errors, source and cleanup errors; pure cancellation remains distinct.
- Implemented: App caches one root, merges agents/native lifecycle nodes, and presents narrow role capabilities without internal voice session access.
- Implemented: removed replaced entry points, peer lifecycle ownership in Assistant and shared perception/synthesis session ownership.

## Acceptance

Test root/child identity and isolation, concurrent lifecycle, partial startup rollback, cancellation, joined stop, terminal rejection, foreground generations and unique registration/output consumers. Regress existing business flows. Run scripts/check.sh and scripts/build-ios.sh. Record actual results separately from native UI, real model and physical device acceptance in docs/validation/Agent-Containers.md.

Branch: codex/agent-container.

## Status

Code migration is implemented. Automated/build evidence and remaining native UI, real model and physical device acceptance are tracked in [validation](../../validation/Agent-Containers.md); acceptance is not complete until those independent checks are recorded.

## Assistant robot Skill on demand (2026-11-04)

Remove robot-interaction from Assistant Agent.json baseSkills; basic-skill and expression-interaction remain resident. Keep the Skill in the discoverable catalog and teach BasicSkill to load it for arm/motor/gesture requests before execution. Robot actions and actions.robot/actions.robot.motion observations become available only while the Skill is loaded; preserve existing recent/Task retention, release and Gateway scheduled XML policy. No device execution, framework, module or directory changes.

Affected owners: Resources/Agents/Assistant configuration, Resources/Skills/BasicSkill discovery guidance, Assistant/Skills technical READMEs and focused configuration/lifecycle regressions. Replace tests that classify a robot Action as permanently resident with a true expression base Action. Verify default absence, discovery, load/use/release, observation selection and immutable earlier catalog. Run scripts/check.sh and scripts/build-ios.sh; record automation/build separately from real-model/device acceptance.
The deterministic serial acceptance fixture must explicitly load robot-interaction before sending its prewritten motion XML; hardware tests remain opt-in. Specialist integration coverage now performs actual XML loadSkills through Control scheduling before the Robot action, rather than assuming resident robot functions.
Deterministic NexArm/Bluetooth/recovery/serial fixtures share a recently loaded Robot context constructed through the production Skill state transition; fixed-host loadSkills remains Task-scoped. The model-driven Specialist test validates Task-free XML loading. No host-policy relaxation is part of this change.
Robot Skill on-demand change is implemented. Full check exit0 (1014 main integration and225 native runtime tests plus other configured products), iOS four-target build exit0, real Qwen discovery2/2 and targeted load/release/Bluetooth recovery checks passed. Evidence and interrupted stale-fixture runs are documented in docs/validation/Agent-Containers.md and Robot-Skill-On-Demand-Model.json. Physical-device/arm acceptance was not performed.

## ModelKit统一Chat并发与本地串行（2026-11-04）
仅调整此前独立Chat租约机制：删除固定两个额外槽位和ChatLease/close/reopen；ModelKit提供固定配置的轻量ChatModel及统一chat入口，Agent仅持有能力与模型名称，Writer按run保留配置句柄而不管理资源租约。思考参数、流式协议、输出默认值、HTTP诊断和超时修正均保留。
云端同一客户端允许多请求，Core资源增加显式并发租约策略，默认互斥供其他后端使用；每请求取消/完成独立，卸载与根停止加入所有在途请求。云端配置通过现有ModelManager按不可变配置复用客户端，不限制云端请求为两个。沿用现有注册资源容量，配置建立失败明确返回。
本地所有Chat请求共用SDK根下一个FIFO：最多1运行、8等待（ModelContainer可配置），满时接纳失败不返回假session。接纳立即返回独立InferenceSession，queued/running/终态可观察；等待取消释放名额，运行取消须加入底层清理后才启动下一项；根暂停/关闭取消并加入等待与运行，不影响其他根。Session提供清理完成加入端口，Provider在原生退出后完成；生成事件/上下文仍独立。等待容量不含已结束句柄，不设输出总量/生产轮数/任务总超时。
实现归现有Core资源/Session、Management ChatDefaults和ModelContainer；Agent/Actions仅切换配置句柄注入，删除被替代的Writer租约清理。既有目录内完成。先验证共享云端并发/取消隔离、本地FIFO与8项容量/取消加入/失败推进/根停止、配置快照与Writer暂停续作，再跑check和iOS构建。同步受影响README，真实模型/设备验收独立报告。
移除Writer租约卸载后，控制/内容请求和Assistant driver必须在成功/异常/取消出口加入对应InferenceSession的原生清理，保留任务终态的清理屏障；不恢复模型资源管理。正常已消费完的session不因收尾cancel变为取消态，未消费缓冲仍按原契约取消抑制。
统一Chat并发/串行改造已实现，固定两槽/ChatLease/Writer close-reopen路径删除；配置句柄、共享云端多请求、本地一运行八等待及session清理加入落地。完整check和iOS四目标构建exit0，证据/替身与实际平台边界见docs/validation/ModelKit-Chat-Concurrency.md；真实模型和设备未在本专项复验。
