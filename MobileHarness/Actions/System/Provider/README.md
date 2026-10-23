# System/Provider — 业务能力与执行

## 职责与关系

URL／密钥只在会话私有暂存和凭据端口中传递，函数参数仅带请求 ID。恢复／保存共享实际事务屏障；提交与回滚使用原始结果，不把后续清理失败改写为未发生提交。纯表单草稿、默认选择和忙态由基础 UI 的 SettingsFormController 拥有。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [ProviderActions.swift](ProviderActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [ProviderDiscovery.swift](ProviderDiscovery.swift) | 私有发现配置、错误与聊天模型列表过滤 |
| [ProviderDiscoveryRequests.swift](ProviderDiscoveryRequests.swift) | 会话隔离的有界发现请求暂存 |
| [ProviderModule.swift](ProviderModule.swift) | 发现与配置操作的函数绑定 |
| [ProviderSettingsRequests.swift](ProviderSettingsRequests.swift) | 配置请求的阶段、领取和结果槽 |
| [ProviderSettingsService.swift](ProviderSettingsService.swift) | 排他恢复／保存、模型切换和持久化回滚 |
| [ProviderSettingsStore.swift](ProviderSettingsStore.swift) | 配置文档与凭据引用的一致性 |
| [SettingsCredentialAdapter.swift](SettingsCredentialAdapter.swift) | Keychain 凭据协议实现 |
| [SettingsProviderAdapter.swift](SettingsProviderAdapter.swift) | Provider 实际发现、配置运行时和结果呈现 |

## Provider 请求暂存与容量

ProviderDiscoveryConfiguration 不可 Codable，保存 URL/key 私有值。ProviderDiscoveryRequests 是 actor：stage 校验 URL/key 最大 2048/4096 字节，为待领取请求设置 10 秒期限；领取前核对 sessionID，领取时移除待领取项，再执行注入发现工作。完成结果由相同会话读取或 discard；错误转换为安全 Provider 分类。

stage 以待领取项加 completed 项少于 32 作为准入条件。

ProviderSettingsRequests 是 MainActor 所有者，共最多 32 个 staged/executing/completed 条目。未领取期限为 10 秒；session、操作种类、阶段与期限必须匹配才能执行。active 不能被 discard，完成值可 result/take，take 移除记录；执行失败移除记录。没有自动过期 worker，过期待领取项在 stage 时过滤。

ProviderModelList 对至多 2048 个非空、最多 512 字节的 ID 进行应用聊天模型族过滤、保序去重；发现暂存端点先拒绝原始重复 ID，编码拒绝超量或超 65536 字节结果。该启发式不证明远端模型的协议兼容性。

## Provider 事务与凭据

ProviderSettingsService 在 MainActor 上拥有 saved/restored/changing、一个共享 restoration Task 和至多 32 个恢复等待者。并发 restore 加入同一个恢复任务；恢复读取持久化后调用 prepare 返回的 apply，成功才设置已确认状态。调用者不各自创建恢复工作，单个等待者取消不等同于取消共享恢复任务。

save 排斥其它更改和在途恢复：校验选项，prepare 获得 apply，加入 beginChange 屏障，持久化后应用，最终 endChange。应用失败时用独立 Task 加入持久化旧值回滚；回滚失败同时保留两个安全原因。此回滚是文档回滚，不保证原生状态能撤销。summary 仅在 restored 后返回 cloudEnabled/selectedCloudModel。

ProviderSettingsStore 是 actor，以 busy 排斥重叠读写，保存 version=1 的配置文档和 credentialID 引用。ProviderCredentialStorage 注入原生凭据读写；原文 key 不存入配置文档。迁移旧凭据时，先提交新文档，再重新读取并核对，成功后移除旧记录。

替换时先写新凭据，再按 revision 保存文档；文档失败时尽力删除新凭据，提交成功后尽力删除旧凭据。凭据清理是 best effort，可能留下无引用记录，不将已提交配置改判为未提交。原生凭据策略及原始网络错误不进入协议结果；安全失败码与有界摘要由 ProviderSettingsError 提供。


[所属域设计](../README.md) · [Actions 模块](../../README.md)
