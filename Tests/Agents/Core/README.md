# Core tests

## 容器与直接输入覆盖

GenerationRoundTests 的 fullDuplexReACTRepliesReachCaptions 使用替身模型分别生成 Action/native Tool 观察及后续正文，通过真实 ConversationPresentation 校验新 Decision 的字幕替换、轮次继承及旧 Decision/取消轮次拒绝；不代表真实网页、模型或原生字幕渲染验收。

AgentContainerTests 使用生产 AgentContainerLifecycle 和可控 gate，覆盖冷根失效、真实 ApplicationLifecycle 初始 inactive → active 组合、启动在途取消、并发启停、部分启动回滚、必须暂停、迟到恢复围栏、终态拒绝及原始／清理失败。AgentSpecialistTests 验证 Assistant 前后台切换不控制平级角色。

iOS 条件用例验证 ApplicationContainer 同根缓存、七个子能力身份和跨根隔离，需要 iOS 测试宿主；macOS check.sh 不执行这些用例。具体执行状态归[容器验证](../../../docs/validation/Agent-Containers.md)，README 只定义覆盖范围。

| 用例边界 | 观察行为 |
| --- | --- |
| 角色 UI 输入 | 真实子容器请求／回执、单消费者、容量、独立控制、暂停恢复、取消加入、版本／来源隔离；设置私密参数暂存与失败呈现 |
| 存储／公开 State | 无效果构造、打开恢复失败、停止与读写竞争、旧仓库拒绝；公开编码／作用域／代际／预算，完整 Context 不进入公开事实 |
| 原生媒体 | 只读 PCM／CameraFrame 直接消费、原采集序号、布局与新鲜度、唯一有界缓冲、半双工丢弃、停止加入及旧回调围栏 |
| 视觉输出 | latest 替换／会话隔离、离散结果保留、慢消费者、真实溢出、终态排空、输入结束／输出失败、错误证据及呈现 |
| 容器异常 | 同根注入、原始错误与清理错误、取消分类、去重／容量、来源与关联；真实 Gateway／ApplicationControl／Actions 呈现和防递归 |
| 首页准备 | loading／checking／ready 事实、真实呈现调用完成类型、代际及乱序版本、验证失败的完整错误链 |
| 原生执行替身 | 语音权限／准备／停止围栏、播放清理、设备连接恢复和旧反馈隔离；替身不证明物理完成 |

FeedbackActionTests 的 iOS 原生触觉用例通过 HAPTIC_DEVICE_ACCEPTANCE=1 显式启用，保留共享会话还原和清理失败；平台 API 接纳不代表实际震感已确认。其他真实模型／设备 gate 同样必须独立报告。

## Container 上下文

ContainerContextTests覆盖读取真实拥有者、来源去重／容量／编码、关闭及同名会话替换、取消、Skill读取集合、Task会话隔离及指令路径。Storage寄存器专属测试已被替换；原有相册／摄影／权限执行回归保留。

## State summaries and explicit queries

ApplicationControl tests cover unknown/admitted/paused/stopped summary reads, per-field sequence fencing, closed scene values and exclusion of raw environment/private result data. Production catalogs reject the removed generic environment address while preserving specific device queries. Shared and Qwen fixtures register an explicit synthetic agents.application owner. Photography/ReACT assertions verify its changes in subsequent actual requests. GenerationRoundTests exercises the registered Bluetooth detail query on Query, real Action feedback and continuation without native Tool calls. These fixtures do not establish real LLM adherence or hardware readiness.

ActionContractTests 直接验证生产 Device.control 生成声明，覆盖携带会话 fence 的连接／忽略与完整可信 UI 操作集合，并检查未知参数、非法操作仍在执行前被拒绝。此测试不访问真实蓝牙或机械臂。

NexArmAimTests 覆盖位置跟踪的方向、死区、有限前瞻/六轴边界和速度/模式/扭矩寄存器拒绝；NexArmBluetoothTests 使用替身验证单目标有限位置包及取消后无追加运动。无真实机械臂验收。

位置跟随回归覆盖 20 Hz 发布、采样率无关的位移/滤波、过时输入和卡顿、慢 Gateway 消费者仅执行最新待发目标、未接纳提案隔离、3 count 更新及 SDK 设备参数边界。混合生产者 BLE 预算和背压测试验证约 33 Hz 连接级上限；替身测试不证明物理平滑或舵机保护。

NexArmArrivalPolicyTests直接验证PlatformKit六轴容差边界、非法反馈配置的原生错误以及原生恢复分类/有界退避；现有动作测试验证SDK观察结果到动作报告的映射。

NexArm relative-motor regression covers encoder conversion, all-axis bounds, fresh measured starts, failed reads without cached fallback, mutually exclusive arguments and rejected writes. Robot workflow scoring rejects wrong axes, order, missing steps and extra moves; live model workflows use synthetic device execution only.

## Reflexive State regression

ContainerContextTests validates passive cold reads, expression override/cancellation/restoration, internal tree paths/depth/capacity/cancellation/partial failures, per-owner health preservation and Skill load/release selection. NexArmBluetoothTests uses an explicit simulated passive link to verify encoder positions, freshness, disconnected-session invalidation and zero control writes/queries. These tests do not establish physical-device acceptance.

ContainerContextTests covers Assistant-owned Business selection, nested-field exclusion, fresh reads, unknown observations, propagation of read failures and independent full Runtime inspection. Native robot tests read the unified State contract.

State audit regressions cover seven-schema wire equivalence and exact UInt64 counters, direct Storage child/tree equivalence without I/O, diagnostic and form-outcome classification, motor outcome/code separation, native quarantine versus valid feedback and invalid category/descriptor rejection.

Single-node regression covers path-only Reference encoding, exact descendant lookup without ancestor/sibling reads, root/catalog zero child reads, weak-owner capability expiry, explicit diagnostic traversal, canonical Skill source equality and unchanged generation/cancellation/bounds. Prior recursive snapshot fixtures are replaced by explicit node catalogs.

PlatformStateTests covers startup seeding, resident reads without resampling, event coalescing, collection failure/recovery, clock updates without readers, generation replacement, foreground reseeding and permission-sharing across child containers. AgentArchitectureTests covers passive Context reads before initialization and after failed restoration. NexArm reflection tests read the publisher-owned resident State without issuing commands or consuming the business stream. Camera read purity is additionally enforced by the architecture audit and compiled in the iOS Simulator build; these checks do not establish physical-device behavior.

State decoupling regression verifies model speech routing stays Runtime without provider preparation, storage root lifecycle failure remains health/issues, permission child reads preserve cached-source errors, scope owner serialization uses stable raw values, and Assistant selection leaves a real producer’s complete Business/Runtime State unchanged.

ActionsContainer regression tests cover native suspension joining before resume and failure preventing admission reopening. SoundSource observation integration explicitly configures Gateway at the host boundary.

The explicit Actions root registration test verifies that repeated registry access returns the supplied root and preserves its stopped state.

Resource-context regressions cover inherited lease resolution, missing-owner rejection and transient-versus-settled holdings. Existing failure-channel tests cover lifecycle-error suppression while retaining journal evidence. Retired App-only health-summary/diagnostic-projection tests were removed with the unused APIs.

聆听控制回归由 ActionAuthoringTests、BehaviorAssemblyTests 与 VoiceTests 覆盖：公开无参数入口、参数拒绝、失败/取消、根会话和弱绑定端点校验，以及许可撤销后回复终态不重开、显式再次启用和不递归排队。受控替身不证明真机麦克风停机或模型退出意图命中。


Perception camera UI intent is exercised through Photographer, fixed Perception Actions and Gateway with a test capability. Camera Foundation snapshot reads are checked for no lazy creation or device activation. Synthetic camera fixtures publish actual-state fields separately from business intent; device results remain independent.

CameraSamplingTests validates native-selected preview/photo geometry, accepting native quarter-turn output dimensions and rejecting incompatible aspect, invalid sizes, over-budget buffers and absent compatible photo formats. WindowGatewayTests verifies Vision aliases resolve only to Camera.Perception Actions while photography retains Camera.Capture; BasicSkill grants neither. PromptTemplateTests also checks that both cold and Photography-loaded Assistant prompts receive the vision/photo routing guidance. Geometry, catalog and prompt tests do not substitute for AVFoundation device capture or real-model intent selection.

NativeImageCompressionTests exercises a synthetic noisy JPEG above4MiB through camera preparation: orientation and aspect are preserved within the4MiB result budget, while the ordinary input budget still rejects that original. Smaller camera JPEGs retain exact bytes/EXIF; explicit input byte/dimension/pixel limits, malformed/oversized input and cancellation fail explicitly. These image-processing tests do not trigger a physical shutter or exercise AVFoundation callbacks.

Camera preparation also uses a padded synthetic mirrored JPEG to verify that normalization preserves visible left/right composition instead of flipping the front-camera image a second time.

## 文件归属

- [AgentArchitectureTests.swift](AgentArchitectureTests.swift)
- [AgentConfigurationTests.swift](AgentConfigurationTests.swift)
- [AgentContainerTests.swift](AgentContainerTests.swift)
- [AgentSpecialistTests.swift](AgentSpecialistTests.swift)
- [AgentTaskSkillTests.swift](AgentTaskSkillTests.swift)
- [BehaviorTranslationTests.swift](BehaviorTranslationTests.swift)
- [CommunicationTests.swift](CommunicationTests.swift)
- [ContainerContextTests.swift](ContainerContextTests.swift)
- [ContainerFailureTests.swift](ContainerFailureTests.swift)
- [GenerationRoundTests.swift](GenerationRoundTests.swift)
- [RuntimeTests.swift](RuntimeTests.swift)
