# Bounded Shared Cache

## 职责与接口

✅ StorageCache 只依赖 StorageCore。CacheContainer 组合 BufferCache 与显式申请的会话 AudioCache。images 和 namespace(name) 是共用预算的字节访问端口，不引入图片框架或业务解码。

CacheBuffer 持有不可变 Data，Cache 存取只转交相同实例。CacheLease 提供有界同步 withUnsafeBytes 读取并显式 release，最后引用释放也退还租约。读取结果要求 Sendable，裸指针不得逃逸；接纳外部 Data 时遵循其值/COW 语义，外部可变裸内存须先冻结或在入口复制，不承诺 SDK 转换无拷贝。

## 容量与生命周期

字节缓存默认 256 对象/64 MiB；每个对象最多 256 租约。删除 key 后，仍由租约持有的对象继续计费；最后租约释放才退还预算。超限拒绝，禁止自动淘汰活跃播放或被租约持有的内存。关闭失效租约访问，已进入的同步读取保持内存安全，最后引用释放才回收字节。

最多 64 个同时音频作用域；同一活跃 scopeID 返回同一 AudioCache，关闭加入相同清理，后续显式申请创建新实例。beginClosing 同步拒绝新命名空间存取和既有 AudioCache 的新句柄/读取接纳；close 加入全部音频清理。音频帧持有共享 CacheBuffer，append/next 不重建字节。

[音频契约](Audio/README.md) · [Storage](../README.md)

## 待完成

❌ 原生音频 Data 到播放 Float 数组的转换仍有复制；图片处理业务、多消费者音频及持久化音频不在本轮。

## 统一容器异常通道

✅ CacheContainer/BufferCache/AudioCache 共享 StorageFailureReporter，缓存拒绝与流失败报告后仍保持原失败/释放语义；没有新增缓存或逐帧诊断队列。


✅ AudioCache 区分句柄正常释放与失败；正常回收不进入统一异常通道，真正的缓存访问失败仍保留原错误与上报。

## Passive state reads

CacheContainer.stateSnapshot returns StorageCore.StorageStateSnapshot directly, with all budgets, handle counts and closure in Runtime and a matching snapshot.stateDescriptor. BufferCache.runtimeStatistics is the low-level locked observation used to compose the container State; it is not another container State format. It neither acquires a buffer lease nor creates an audio scope. Retained bytes include live leased storage, so removing a key does not imply memory release.
