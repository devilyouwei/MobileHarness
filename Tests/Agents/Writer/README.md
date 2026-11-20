# Writer tests

Agent 生命周期、角色和评测中本目录能力的测试。测试通过真实接口及显式替身验证可观察行为、失败、取消和清理；真实模型及设备用例保留显式 gate。

## 文件归属

- [WriterAgentTests.swift](WriterAgentTests.swift)

[WriterEvaluationRunnerTests.swift](WriterEvaluationRunnerTests.swift) 拥有通信辅助机制的确定性回归及单模型、单任务、最多8次请求的 smoke（默认关闭）。多 case/模型效果对照归 experiments。


[WriterWorkflowTests.swift](WriterWorkflowTests.swift) 使用脚本模型验证控制/内容流、恢复、取消、提交和工具配对；保持 AppWorkflowTests 编译边界，使用该 target 的 WorkflowCatalogFixture 安装生产声明。取消等待有截止时间并加入任务终态，初始化失败不会导致无限循环。

[WriterCommunicationFixture.swift](WriterCommunicationFixture.swift) 拥有单次 delegate smoke、原生渲染/schema工程回归所需的临时工作区与宿主；不提供批量模型评估入口。

WriterTestRequester 是仅限工程测试的请求方所有者：装配时绑定常驻 Writer 频道，发请求前只登记任务/session，独立补读持久结果、去重/确认和清理跟踪。消费者拒收回归由该请求方恢复，不要求 Writer 根据消费结果重发；发布状态与消费状态分别断言。
