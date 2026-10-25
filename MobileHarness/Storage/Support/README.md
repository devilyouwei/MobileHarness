# Common Storage Mechanisms

✅ StorageFailure.swift 的物理文件移到模块根，仍由 StorageCore 编译；Support 的 Contracts／Memory 继续复用该定义，不引入根容器目标依赖。

✅ StorageCore 编译 Contracts 与 Memory，无其他项目或第三方依赖。Contracts 提供身份、持久化标识、通用错误和指纹；Memory 提供有界流、owner 租约与接纳门。Cache、Files、数据库领域和后端使用这些机制。

文件与文档契约归 Files；运行状态归所属外部 Container；音频归 Cache/Audio；SQL 机制与领域 SQL 实现归 Database/SQLite。公共机制不解释业务状态、模型、设备、UI 或 SQL schema，不提供全局查找与后端回退。

[契约](Contracts/README.md) · [内存机制](Memory/README.md) · [Storage](../README.md)

## 待完成

❌ 新机制须由实际消费者需要驱动；不增加空适配后端。

## 统一容器异常通道

✅ StorageFailureReporter 属于 StorageCore，仅 Foundation；统一非阻塞错误回调，普通 CancellationError 不升级。它不存储历史、不执行 UI/Agent 或重试。

✅ 已实现：统一报告端口完整转交原始 Error，不在基础库删除取消证据；不选择业务呈现。


✅ StorageFailureReporter统一构造StorageFailure；底层领域错误保留在underlying，不吞取消，不决定展示。结构由模块根目录 [StorageFailure.swift](../StorageFailure.swift) 定义，编译归属仍为 StorageCore。
