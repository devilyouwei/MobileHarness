# Storage 四类容器、IoC 与 State 基础

状态：✅ 代码、接口迁移及专项行为已实现；❌ 全量感知回归和 Simulator 构建限制仍保留。用户已批准 Storage 子目录重组；不新增一级模块，不自动提交或合并。

## 结构与边界

App 用 FactoryKit 3.4.1 的独立 ApplicationContainer 注册 StorageContainer。根组合 state/cache/database/files；FactoryKit 不进入业务或 Storage 目标。StorageCore 保留公共机制；StorageState、StorageCache、StorageFiles、StorageDatabase 保持独立；StorageSQLite 独占 GRDB。AppStorage 复用 App/Composition 中的注册源码。

State 提供类型化注册、Reader/Writer、代际、CAS、同步纯转换、一致快照、有界观察。默认 256 项、64 作用域、64 观察者；通知保留最新一项。AgentContext 当前由 Agent actor 私有持有，业务事务和 Task/Skill 规则不变；State 只保存有限公开事实，Skill useState 每轮取新快照。

Cache 提供不可变共享缓冲区、命名空间与租约，默认字节缓存 256 对象/64 MiB；音频保留 32 句柄、8 MiB/2048 帧、单消费者和 owner 校验。会话显式申请/关闭音频子作用域。零拷贝保证限于 Cache 存取与交接，原生播放格式转换保留。

Database 保留 chat/tasks/media/devices、共享 SQLite 池和既有恢复/关闭契约。Files 合并文档与字节入口，保留 settings/photos/models 原路径、envelope、版本校验、保护、发布和真实目录能力。照片仍由 CapturedPhotoStore 组合元数据和文件。

## 生命周期与实施

构造无磁盘效果；根 start 准备子服务，失败清理且保留原始和清理错误；stop 先关闭接纳，再加入清理，重复停止共享结果。应用顺序 storage → agents → native；清理失败阻止替换。

先文档、目录和编译边界，再 State、Cache、Files/Database、App 注入；清除旧实现并同步全部当前路径引用。持久化格式、Signal 路径、UI 本地状态和资源锁不改。

## 验收

覆盖实例隔离、构造无效果、失败回滚/取消/重复停止；State 类型/权限/版本/代际/快照/观察/容量；共享内存和租约、音频 owner/排空/取消；文件冲突/越界/照片恢复/模型路径与旧接口关闭；依赖无环、唯一编译归属、IoC 边界。

执行 scripts/check.sh 和完整 Xcode 下 scripts/build-ios.sh；保留原有测试与 CoreAI 构建限制，分别记录自动化、构建、模型、UI 和设备证据。

## 实施对账

- ✅ 四类目录、独立编译目标、StorageCore 与根 StorageContainer；移除 StorageAudio、MemoryStateStore 和具体文件后端分散构造。
- ✅ AppStorage 使用 FactoryKit 3.4.1 实例缓存，业务通过构造器注入端口，保持 storage → agents → native 生命周期。
- ✅ State 注册、读写能力、代际、CAS/纯转换、一致快照、有界通知和旧端口失效；AgentContext 私有内存与有限公开投影分离，不复制 Task/Skill 权威对象。
- ✅ Cache 共享缓冲区、租约计费、会话音频；Files 文档/字节/目录统一并保留原格式与路径；Database 保留恢复和关闭契约。
- ✅ 模型后台下载复用注入服务；Files 释放前加入制品工作并解除旧绑定，避免新根引用已关闭后端。
- ✅ 新旧实现清理、路径引用、文档与源码归属对账；❌ 全量感知回归和 Simulator 外部依赖限制不能判为通过。

详细结果见 [验证记录](../../validation/Validation-History.md)。真实模型/UI/物理设备未验收；本轮交付不等同整个资源 State/Skill 上下文需求完成。


✅ State 边界已修订：AgentContext 使用私有 actor 内存，公开寄存器只承载有限事实；以 [公开 State 计划](../Resource-State-Plan.md) 为现行范围；历史记录保留此前实现与验收限制。
