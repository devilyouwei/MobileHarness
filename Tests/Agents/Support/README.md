# Support tests

Agent 生命周期、角色和评测中本目录能力的测试。测试通过真实接口及显式替身验证可观察行为、失败、取消和清理；真实模型及设备用例保留显式 gate。

## 文件归属

- [ContainerExecutionFixtures.swift](ContainerExecutionFixtures.swift)
- [DirectInputSupport.swift](DirectInputSupport.swift)
- [FixedTextChat.swift](FixedTextChat.swift)
- [FixtureCommunications.swift](FixtureCommunications.swift)
- [SpeechRequestProbe.swift](SpeechRequestProbe.swift)

[WorkflowCatalogFixture.swift](WorkflowCatalogFixture.swift) 为原 AppWorkflowTests 编译目标安装生产 Action 声明，避免测试依赖其他进程的初始化顺序；IntegrationTests 继续使用 Actions/Support 的 ActionCatalogFixture，各 target 独立执行时都明确初始化。
