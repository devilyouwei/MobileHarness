# App Workflow Tests

✅ 回复等待采用独立更新序号，沿用现有会话／轮次围栏，迟到旧轮请求不能接管新轮等待。

✅ 准备取消回归改为真实生命周期失活；覆盖准备验证失败只报告一次且可重试，旧代际不报告失败，具体加载错误不重复报告为验证异常。

✅ 快速前后台回归要求即使前台 worker 尚在等待，也按 true → false → true 交付；native 暂停中快速 active 的 gate 用例，确认 Agent 暂停/取消完成先于任何恢复。

## 职责与边界

测试 App 的根生命周期、Feature workflow、独立输出消费及注入端点的呈现/原生适配。状态、取消和完成以显式 gate 同步，不把合成回执作为模型或设备验收。业务函数的参数/执行器和真实记录仓库跨 Gateway 的验证属于 IntegrationTests。

## 当前用例

| 文件/组 | 契约 |
| --- | --- |
| ConversationHistoryWorkflowTests | 历史 façade、归档/标题/删除的独立 owner、冲突和取消后的已提交事实 |
| ActionActivityTests / ConversationPresentationTests | Action/task 展示值、错误链、真实取消与 root scope 的投影 |
| IndependentOutputTests | 各协议消费独立、拒绝不丢后续输出、取消与实际执行终态 |
| SettingsTransactionTests / SettingsInteractionTests | 先提交后应用、草稿/私有结果、操作重叠、失败与显式重试 |
| ModelResourcesWorkflowTests / ModelResourceInteractionWorkflowTests | 保存源、偏好、资源准入/删除、配置前置条件与页面无关 lifetime |
| ResourceObservationWorkflowTests | 资源变化触发无参数通知，不轮询或生成序号；重复前台不重订阅，shutdown 取消并加入 |
| AudioDetectionWorkflowTests | 权限/首帧、自动完成、单次接纳、取消清理和晚到回调 |
| ListeningActivationTests / ListeningCaptureWorkflowTests | 能力/权限准备→首帧收音→并行 cue/haptic、阶段失败保留实际效果、取消 join、同意/占用、半双工与快速切换 |
| NativeInteractionWorkflowTests | UI 手势到 root intent、角色/会话围栏与取消；相机请求失活明确提示重试，保留已保存照片事实 |
| CameraVisionRestartTests | camera/vision 代际替换、取消加入、失效回调和重启次序 |
| PhotoDispositionWorkflowTests | 保存/忽略提交后的反馈失败与取消，不撤销已发生效果 |
| HomeEffectsTests | notice/light/caption 的 owner、替换、时限及纯取消展示 |

所有 façade 只观察注入的结果，不查询/拼装未授权的底层能力。偏好提交后的应用失败保留真实持久化结果；错误处理和状态轮询不得隐式重放效果。Root-owned 操作独立于页面，取消和替换必须加入实际清理。

## 组合根与集成回归

测试显式导入 Agents、Actions、AppLifecycle、Gateway、PlatformKit 和相应基础目标，不依赖 AppWorkflows 统一导出。ApplicationLifecycleTests 覆盖非法/超限图、依赖顺序、重复停止、部分启动回滚、保留多个清理错误、启动中的即时后台失效和迟到完成。

旧功能回归仍通过实际拥有者接口验证关联、容量、取消和真实完成；iOS 原生接入源由真实 iOS build 核验，macOS 条件编译不会提供假的设备实现。


生命周期回归补齐 active 前等待、后台启动取消的正常 suspended 结果、快速前后台切换、停止唤醒等待者及清理失败不能伪装为正常暂停。

## 待实现

- 原生手势、配置/Keychain、麦克风/相机/声学与设备接管验收。
- 后台传输、真实计时/负载和持续跨场景运行验收。

用例文件是当前契约入口；构建和执行结果归 [validation](../../docs/validation/README.md)。

UI 呈现边界回归覆盖设置修订拒绝过期更新、实际表情动画回调与迟到回调围栏，以及取消后等待结束。

## Storage 依赖

✅ 存储访问使用独立的 State、Cache、Database 和 Files 接口；App 注册根实例，消费者通过构造器获得所需能力。存储容器不接管本目录的业务验证、执行和完成语义。


## 分类异常诊断

✅ 验证异常分类从 Gateway 快照到 Agents/UI 的短 toast 与完整日志双通道，保留关联信息及取消/去重/过期契约。

## ApplicationControl 异常展示

✅ 已实现：原异常提示策略回归迁到 IntegrationTests/ContainerFailureTests.swift，经过真实 Gateway/ApplicationControl/内部函数验证；本目标保留纯展示和 workflow 投影测试，不再假定 recordFailure 同步直接更新 UI。

## UI 全量容器化

✅ 应用级 UI 状态由八个子容器统一创建，消费者注入所需 Presenting 接口并提交 UI 自有值，不直接写字段。App 注册并管理同一 UI 根；原业务身份/版本校验、原生完成和基础库依赖边界保持。跨模块连接迁移仍是独立待办。

✅ 相机点击回归覆盖同步忙碌、重叠拒绝、成功/失败后的忙碌与控制提示清理，且不覆盖原生设备错误。

✅ 覆盖模型资源恢复合并、下载源编辑防抖／忙碌后续存、停止加入与错误不重放，并保留偏好失败后的显式恢复重试。

✅ 已实现：覆盖宿主准备步骤跳过、串行／合并、取消加入、失活代际、失败重试及活动会话延后，使用可控屏障测试，不以替身代替模型验收。

✅ 已实现：覆盖重复首页激活时暖模型不准备、prepare 后复查投影 checking。

✅ 已实现：准备函数已进入但未收到真实加载回调时仍为 checking；代际围栏拒绝迟到加载开始。

✅ HomeEffectsTests 覆盖恢复聆听时清理已定稿用户字幕（含无回复文本），不清理新一轮部分转写，旧回复到期后新输入仍保留。

✅ 已实现：ListeningActivationTests在同一会话、同一反馈端点连续执行五次独立启动，逐次验证先收音再执行提示音和触觉、子context及成功回执；替身只证明重复提交，不代表真机震动。


## Direct container contract

Direct-input regressions cover typed request receipts, bounds, cancellation/generations, native subscriptions and unchanged authorized execution. Synthetic tests do not establish real model, UI or hardware acceptance. Current cross-module ownership is defined by the [overall design](../../MobileHarness/README.md).

✅ 通过屏障持有扫描请求，确认停止扫描可在扫描终态前提交，根关闭加入普通与控制 worker。

## 语音执行归属收敛

✅ 已实现：语音实际执行迁入 Actions 后继续验证聆听激活顺序、失败反馈、原生关闭加入、播放恢复、取消及独立输入消费；原生 iOS 执行与真机验收分别记账。

## 直连链路收尾（待实现）

❌ 验证业务完整终态及设备互斥，测试同步使用明确屏障。

✅ HomeEffectsWorkflow 的 owner 围栏直接使用 UI.PresentationOwner 测试；移除已退役的 FunctionInput 身份转换扩展依赖。Actions 授权与调用参数仍由 HomeEffectActionTests 验证。

✅ 环境事实源覆盖同类合并、投递失败和停止加入；不以应用壳直接写失败记录代替 Agent 决策。


## Actions 接入契约

Actions 按业务能力组织源码，保持原编译目标。生产调用显式连接独立相机、语音、UI 呈现和 Task 端点；不通过无关能力的类型转换探测。验证和导航按实际源码所有权维护，业务授权与生命周期继续由原拥有者负责。

## Agents 角色与共享机制

具体角色装配归 Agents 根级，Support 保留通用机制；角色私有载荷和会话控制由角色解释，通过注入的解码／Context 钩子接入共享准入。输入身份、Task scope、取消加入和真实结果保持独立，源码和验证按其实际所有者维护。

✅ 相机已提交保存、后续UI请求失败时，断言保留“已保存到 App 相册”的真实提交反馈；保存目标不再是系统Photos。

## Gateway container ownership

✅ Generic service-graph ordering and rollback remain covered here. GatewayContainerTests in IntegrationTests additionally exercises a real Gateway root under ApplicationLifecycle to verify executionBindings → gateway → agents ordering and retained binding lifetime.

## Application observation worker

ApplicationEnvironmentInputsTests exercises the existing bounded per-category worker with model-preparation loading/idle replacement, independent scene/device admission, explicit failure reporting and joined shutdown. Navigation is read directly through UI State and has no duplicate environment category/report. These tests exercise delivery mechanics with synthetic facts; role summary validation belongs to IntegrationTests.

WindowExecutionTests supplies lifecycle probes and synthetic UI receipts to verify failure retention, resume ordering, per-instance replacement and close preemption, plus Action input validation. It does not claim real camera/animation acceptance.

Window lifecycle regressions assert the transition gate spans presentation completion and releases on failure. These pure workflow tests do not exercise physical camera capture or iPhone rendering.

后台持续服务回归验证Scene隐藏时不invalidate持续根、默认视觉服务仍失效，返回不重复start，根stop仍完整invalidate并逆依赖停止。

WebWorkspaceTests exercises read-before-edit, unique replacements, path/byte limits, persisted immutable revisions, stale-write rejection, reopening, deletion and the private multi-request editor with a scripted model. Tests also cover cancellation, latest-render image feedback and full Action create/save/partial-update sequencing with an explicit page test double. These deterministic model replies are explicit test doubles and do not establish real model generation quality.


WriterWorkflowTests 使用脚本模型验证原生控制/原始内容流分离、逐字符传递与截断不提交；WebWorkspaceTests 验证通用作品兼容、MD 入口、草稿/发布隔离和过期编辑引用。替身不证明真实模型遵循。

Writer 文件回归还覆盖关联片段与 Unicode 行读取、按文件引用隔离、目录移动的整批校验/恢复、历史版本原生读取，以及追加用户要求和格式规则传入内容请求。

ArtifactArchive 的 ZIP 输出通过独立系统 unzip 校验目录结构/CRC；仅测试进程调用桌面校验工具，手机生产代码不执行 Shell。

智能体大脑表单回归覆盖两个 Provider 并行发现、独立模型选择、稳定身份编辑后迟到结果拒绝、删除引用与关闭加入；查询使用注入替身，不代表真实 Provider 或原生菜单验收。

Current persistence regressions reject retired speech preference switches, missing independent speech fields and Artifact indexes/projects missing current entry/draft/deletion fields; current documents still round-trip and workspaces reopen their versions.

Writer/Artifacts 回归覆盖10个独立作品、18次保留版本、超过64KiB的原生模型内容流、超过32文件/256KiB项目的发布与历史读取；失败工具参数规范化去重及修改草稿后的再次验证均通过真实工作流驱动，模型为显式脚本替身。读取参数错误独立于存储容量。

WriterWorkflowTests验证超过原固定控制轮数后仍由模型finish正常结束，并在有界上下文裁剪后保留当前目标和工具配对；使用脚本模型，不对实际Provider生成质量作结论。

Writer recovery fixtures cover transient/permanent model failures, finite exhaustion, plain-text/batch correction, fresh streams after partial content, uncertain commit and cleanup non-replay, and cancellable backoff. Scripted models retain nil output budgets; productive loops remain unrestricted.

Writer raw-code regressions cover split outer fences, normal JS template literals, legitimate Markdown fences, fresh transaction recovery with corrective instruction, and three failed format attempts without publication. Writer integration tests separately verify schema descriptions/enums and reject undeclared arguments before execution, then permit model correction with complete persisted tool pairs.

Exact replace regressions assert unchanged surrounding UTF-8/newlines/related files, fresh read ownership, unique matches within a narrowed range, empty replacement deletion, stale/cross-file reference rejection, and failure atomicity. This is a deterministic patch operation, separate from model-generated fragment streaming.

WriterWorkflow tests cover natural no-tool termination through the shared finalizer, one progress event per actual request, late accepted revisions and paired native-call results. Fixture revisions are consumed once, matching the production port. No loop-count or output-token budget is added to production behavior.

Writer回合边界回归验证控制/内容请求、文件提交、预览加入、完成汇报、下一请求的顺序；Web定向回归验证Writer窗口读取/截图隔离、无根页面创建、真实目标回执及错误ID拒绝。

设置保存回归检查Writer思考布尔值进入实际保存请求，失败后保留草稿，沿原有单次事务/页面寿命屏障恢复。

Caption ownership regressions verify independent slot updates, retained final/user/reply text after playback, explicit onset cleanup, retired request continuations and delayed clears preserving genuinely new replies, including replies for older queued input turns.

Writer regressions verify parameters above 64 KiB reach execution/next request intact, actual errors enter retry/subsequent context, and aborted content retry includes the failure cause.

Workspace editing/UI regressions remain backend-independent. SQLite persistence, over-8MiB catalogs, concurrent CAS and deletion recovery live in IntegrationTests/WorkspaceRepositoryTests; Writer long-result tests distinguish complete execution evidence from model-only excerpts.

Camera fixtures distinguish previewID from persistent mediaID and preserve committed-save reporting after a later request-completion failure.

History image regressions cover persistent and preview identity validation, exact recorded attachment/input checks, released-preview presentation outcomes, retryable read errors and bounded cancellation-aware reads.

Welcome 设置回归覆盖成功恢复前不提示、恢复失败不覆盖、已有 Provider 不重新引导、空 URL 默认 OpenAI、自定义 URL/Key 修剪、无效输入拒绝、保存失败重试、单次保存接纳、停止后不再发布以及重新创建控制器后的持久配置恢复。测试使用设置操作替身，不访问真实凭据或云端服务。

首次配置后仅为 Writer 选择云端的回归，验证保存/恢复保留 Provider key，不被未启用 Assistant 的空凭据覆盖。
