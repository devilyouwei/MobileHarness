# App Workflow Tests

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

## 待实现

- 原生手势、配置/Keychain、麦克风/相机/声学与设备接管验收。
- 后台传输、真实计时/负载和持续跨场景运行验收。

用例文件是当前契约入口；构建和执行结果归 [validation](../../docs/validation/README.md)。
