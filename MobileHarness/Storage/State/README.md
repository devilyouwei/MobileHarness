# State 公开寄存器

## 职责与直接关系

✅ StorageState 只依赖 StorageCore 与系统能力，保存有必要公开给 LLM 的有限当前事实。上层拥有者定义可编码类型、验证和业务投影；Storage 不认识 camera、robot、task 或 Skill。完整 AgentContext、任务注册表、队列与执行机制保持在 Agents 内部。

## 注册、权限与作用域

StateContainer.declare 安装公开名称及 application/conversation 作用域种类；相同名称不能改用其他种类。makeScope 返回拥有者持有的 StateScope；conversation 显式绑定 agent/session。相同逻辑地址重复注册拒绝，错误类型拒绝。register 返回唯一 StateWriter 及只读 StateReader，端口携带注册代际；读端口不能通过名称升级为写端口。

StateContextReading 只提供 snapshot(names:)。创建会话读能力时必须提供同容器/域的作用域；消费者不能切换身份。应用事实从应用域读取，会话事实严格匹配绑定域，不跨会话回退。注销或关闭后旧端口失效；同名新注册具有新代际。注册端口不延长 StateScope 生命周期。

## 原子发布与快照

✅ 注册与转换先执行纯验证和 JSON 编码，再在同一锁域发布类型化值与编码投影。set(expecting:) 和 transition 校验版本，失败不发布；同步转换/验证/编码不得重入、等待或执行外部副作用。StateValue 返回修订与代际，公开上下文只输出编码事实，不包含内部元数据。

PublishedState 表达 unknown / available / unavailable 及 value（包括 null）。未注册/未知名称、关闭域和失效公开投影明确抛错，设备不可用作为值中的真实事实。拥有者在业务提交后发布失败时调用 invalidate，使公开读取拒绝旧事实；保留原错误与已发生业务效果。拥有者仍可通过类型化端口检查最后提交值并修复发布。

snapshot 在同一 StateContainer 锁域读取所选条目并记录整体修订；不承诺跨容器、私有上下文或 SQL 的事务。跨选定类型化读端口也支持冻结快照。

## 容量、观察与生命周期

默认 256 注册/公开名称、64 作用域、64 观察者；键名非空且最多 256 UTF-8 字节。每个编码值最多 8 KiB，一次公开读取最多 32 个唯一名称，JSON 快照最多 16 KiB；请求构造再校验包含标题的 State 块预算。超限拒绝，不截断。

observe 返回 AsyncThrowingStream，初始通知和后续通知使用 bufferingNewest(1)，允许合并中间修订。它是重新读快照的通知，不是逐转换日志；失效会提高修订并通知。取消移除观察者，注销/关闭结束观察；watch 不自动调用模型、Action 或 Trigger。

## 待完成

❌ 完整写入源治理、Trigger 与更多事实注册由后续需求处理。本模块不增加业务状态机或设备锁。

[Storage](../README.md) · [Skill 读取规范](../../Resources/Skills/README.md)

## 统一容器异常通道

✅ StateContainer 的失败端口与公开操作一起注入；验证、状态注册、读写及快照错误在离开锁后原样抛出并报告。StateScope/Reader/Writer 仍经同一拥有者，错误不会触发再次 State 写入。
