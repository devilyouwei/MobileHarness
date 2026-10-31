# Shared Storage Values

✅ StorageFailure.swift 移至 ../../StorageFailure.swift，StorageError.swift 的领域错误／报告器继续留在本目录，二者仍编译于 StorageCore。

✅ StorageCore 编译本目录，无项目/第三方依赖。StorageOwner 表达命名空间和 source/session/input 身份；StorageDurability 区分内存成功与持久化成功。StorageError、RecordStorageError、DocumentStorageError 提供共享机制错误；BusinessRecordID 与 ContentFingerprint 只格式化/验证及计算指纹，不分配全局身份。

RecordStorageError.notReady 表示数据库端口尚未发布，closed 表示作用域关闭；conflict 表示仓库前置条件被并发变化破坏。错误不包含展示文案，原始失败由生产者保留。

运行状态与上下文由所属外部 Container 和 Agent 读取适配器管理；文档、字节、文件保护与发布契约归 [Files](../../Files/README.md)。各领域返回拥有的数据，禁止跨目标暴露 SQL 对象或共享可写值。

[Support](../README.md)

## 待完成

暂无本目录独立待办。

## 统一容器异常通道

✅ StorageError.swift 新增 StorageFailureReporter，以组件/操作/原错误回调向宿主报告；Storage 子能力共享注入实例，不依赖框架模块。调用者必须提供有界非阻塞接收，不在存储锁内等待。

✅ StorageError.swift 集中声明通用、文档和记录三类错误及注入报告器，值错误统一 Error/Equatable/Sendable；StorageDurability 单独表达持久化事实。各错误名称和 case 保持独立，不用一类泛化错误抹平语义。


✅ 模块根目录 [StorageFailure.swift](../../StorageFailure.swift) 定义Error／Sendable／CustomStringConvertible封装及稳定Code、Source。字段为code/component/operation/message/underlying/cleanupErrors/source；默认记录包装调用处fileID/function/line，不采集线程堆栈。同模块再次包装保留首次来源和主错误，追加清理错误。无额外清理失败的CancellationError才属于正常取消；不认识Signal或业务恢复策略。

## Classified Storage State

[StorageStateSnapshot.swift](StorageStateSnapshot.swift) defines the Codable/Sendable path, Business, Runtime, health/issues, path-only child references, collection time and descriptor metadata used directly by all Storage containers and the database port. It is shared within StorageCore so Cache/Files/Database never depend on the root Storage target. Value includes exact UInt64 counters, scalar/structured data and null unknowns. The contract contains no consumer-specific visibility rule or mutable state.

All Container/node reads use stateSnapshot() async throws. Reference is Codable path-only metadata; Reader is an unencoded weak-owner capability for exact lookup, and Descriptor.children contains indices rather than descendant descriptors.
