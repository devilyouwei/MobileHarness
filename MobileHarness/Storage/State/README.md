# Registered Memory State

## 职责与接口

✅ StorageState 只依赖 StorageCore、Foundation/Synchronization。StateContainer 通过 StateScope 注册 StateKey<Value>，返回 StateWriter 与只读 StateReader；读端口不能通过键名升级为写端口。StateValue 包含值、修订号和注册代际。

## 一致性与转换

get 返回快照；set(expecting:) 和 transition 在同一 Mutex 内校验版本、运行拥有者提供的纯同步规则并发布。失败保持旧值。闭包不可重入 Store、不可等待或执行外部副作用。跨选定读端口的 snapshot 在同一锁域冻结，记录容器整体修订号；不承诺跨容器或 SQL 的原子性。业务类型及转换规则留在注册方，值不能逃逸为共享可写对象。

## 作用域、容量和失败

默认最多 256 注册、64 作用域、64 观察者。键名非空且最多 256 UTF-8 字节；值的大小由拥有者规则校验。重复键、类型不匹配、版本冲突、超限和关闭明确失败。注销后同名注册拥有新 UUID 代际，旧 Reader/Writer 不可写入新值。Scope 的拥有者显式 close 或释放最后作用域引用；注册端口本身不延长作用域。

observe 是 AsyncThrowingStream，初始通知和后续通知使用 bufferingNewest(1)，合并中间修订；它是当前状态失效通知，不是完整事件日志。取消移除观察者；注销、作用域/根关闭结束观察并拒绝旧端口。

## 待完成

❌ Skill 声明、提示词投影和业务状态注册表由上层后续接入，不在本模块引入业务类型。

[Storage](../README.md)
