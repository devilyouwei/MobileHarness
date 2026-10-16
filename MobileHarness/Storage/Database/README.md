# Structured Database Storage

## 职责与接口

✅ DatabaseStorage 提供 start/stop 与抛错的 chat/tasks/media/devices 端口；DatabaseRepositories 是不含 SQL 类型的值集合。领域仓库分别编译并返回拥有的数据，不暴露 GRDB、连接或表对象。Storage 根只依赖该协议；AppStorage 选择 SQLiteDatabaseFactory。

SQLiteDatabaseStorage 在后台任务完成目录、打开、迁移和恢复后才发布端口；失败/关闭不可重开。重复启停共享任务，停止先关闭接纳，再加入初始化和在途操作。原始错误与清理错误分别保留。应用业务先提交终态，再停止数据库。

## 子目录与关系

[Chat](Chat/README.md) 使用 [Tasks](Tasks/README.md) 完成会话检查点及任务关联；[Media](Media/README.md) 保存媒体元数据并组合 Files；[Devices](Devices/README.md) 保存设备记录。[SQLite](SQLite/README.md) 独占 GRDB，并编译这些领域的 SQL 实现。四类仓库共用同一 storageScope 和池，不能混用不同运行作用域的 Chat/Tasks。

## 待完成

❌ 新数据库后端、跨进程运行态和跨文件/SQL 原子事务不在本轮。

[Storage](../README.md)
