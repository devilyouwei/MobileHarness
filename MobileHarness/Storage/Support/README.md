# Common Storage Mechanisms

✅ StorageCore 编译 Contracts 与 Memory，无其他项目或第三方依赖。Contracts 提供身份、持久化标识、通用错误和指纹；Memory 提供有界流、owner 租约与接纳门。State、Cache、Files、数据库领域和后端使用这些机制。

文件与文档契约归 Files；注册状态归 State；音频归 Cache/Audio；SQL 机制与领域 SQL 实现归 Database/SQLite。公共机制不解释业务状态、模型、设备、UI 或 SQL schema，不提供全局查找与后端回退。

[契约](Contracts/README.md) · [内存机制](Memory/README.md) · [Storage](../README.md)

## 待完成

❌ 新机制须由实际消费者需要驱动；不增加空适配后端。

## 统一容器异常通道

✅ StorageFailureReporter 属于 StorageCore，仅 Foundation；统一非阻塞错误回调，普通 CancellationError 不升级。它不存储历史、不执行 UI/Agent 或重试。
