# Settings tests

| 文件 | 层级与边界 |
| --- | --- |
| [SettingsTransactionTests.swift](SettingsTransactionTests.swift) | Unit Tests：ProviderSettingsClient 的确认值与缓存规则，注入保存/恢复；用 fails 参数分别验证成功提交和失败后显式恢复。 |
| [SettingsInteractionTests.swift](SettingsInteractionTests.swift) | Unit Tests / Integration Tests：表单与操作生命周期、共享状态/导航、角色配置；持久化和发现端点按用例注入。 |

settingsFacadeCommitsOnlyAcknowledgedSaveAndReconcilesFailure 使用函数级 @available，旧系统由 Swift Testing 报告跳过，不提前返回冒充成功。UI 点击和原生表单布局不在上述直接调用范围。
