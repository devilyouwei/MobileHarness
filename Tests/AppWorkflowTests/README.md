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
| ResourceObservationWorkflowTests | 根采样、指纹/版本、失败/恢复、单工作者及 shutdown join |
| AudioDetectionWorkflowTests | 权限/首帧、自动完成、单次接纳、取消清理和晚到回调 |
| ListeningActivationTests / ListeningCaptureWorkflowTests | 能力/权限准备→首帧收音→并行 cue/haptic、阶段失败保留实际效果、取消 join、同意/占用、半双工与快速切换 |
| NativeInteractionWorkflowTests | UI 手势到 root intent、角色/会话围栏与取消 |
| CameraVisionRestartTests | camera/vision 代际替换、取消加入、失效回调和重启次序 |
| PhotoDispositionWorkflowTests | 保存/忽略提交、原生退出/反馈、错误与已发生效果分离 |
| HomeEffectsTests | notice/light/caption 的 owner、替换、时限及纯取消展示 |

所有 façade 只观察注入的结果，不查询/拼装未授权的底层能力。偏好提交后的应用失败保留真实持久化结果；错误处理和状态轮询不得隐式重放效果。Root-owned 操作独立于页面，取消和替换必须加入实际清理。

## 组合根与集成回归

测试显式导入 AgentBindings、ActionBindings、AppLifecycle、Gateway、PlatformKit 和相应基础目标，不依赖 AppWorkflows 统一导出。ApplicationLifecycleTests 覆盖非法/超限图、依赖顺序、重复停止、部分启动回滚、保留多个清理错误、启动中的即时后台失效和迟到完成。

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

✅ 验证异常分类从 Gateway 快照到 AgentBindings/UI 的短 toast 与完整日志双通道，保留关联信息及取消/去重/过期契约。

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
