# File and Document Storage

## 职责与接口

✅ StorageFiles 只依赖 StorageCore、Foundation/Synchronization。FilesContainer 配置 settings/photos/models 三个命名空间，公开 document(Value.self, in:name:) 与 file(namespace:)。具体业务 Codable 类型留在调用方；照片字节、配置文档与模型目录共享文件拥有者，但保留不同访问能力。

DocumentStore 提供 load/refresh/invalidate、UUID revision 的 save/CAS 和 replace。FileDocumentStore 保留 envelope version 1、默认 64 KiB、按文件的进程内 CAS 锁和原子替换；MemoryDocumentStore 是显式内存替身。FileStore 提供有界 read/info、putIfAbsent、remove 和有界列举；DiskFileStore 另提供真实目录、空间预留和发布，MemoryFileStore 是显式内存替身，不伪造文件 URL。

## 生命周期与失败

构造不创建目录；start 准备设置目录并排除备份。每个命名空间只属于自己的 FilesContainer，拒绝跨根引用。工厂按位置复用后端，并校验类型、容量和保护配置一致；最多持有 256 个文件/文档后端。beginClosing 同步关闭共享接纳；close，等待后端 actor 中已开始的同步文件操作；重复 close 加入同一任务，旧接口拒绝新读写。

文档缓存只在持久化成功后改变，读取损坏/未知版本/CAS 冲突明确失败。字节路径拒绝穿越、符号链接及容量异常；发布使用临时文件、同步、关闭和无覆盖移动，失败保留主因与清理原因。目录空间预留默认 32 GiB。列举最多四个游标，每页最多 128 项，错误/显式关闭释放枚举器。

模型业务可在受控目录中使用原生 SDK；这些调用由其拥有者取消并加入后，App 才关闭 Files。文件与 SQL 没有联合原子事务。

[Storage](../README.md)

## 待完成

❌ 跨进程文档 CAS、物理存储保护验收；不提供自动磁盘/内存回退。
