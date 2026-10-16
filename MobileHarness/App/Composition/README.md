# Application Composition

## 职责与接口

只创建、持有和连接模块实例，安装模块公开声明及生命周期描述。不接收业务请求、不转换业务数据，也不决定模型/相机/语音/设备业务规则。

## 组件与关系

| 文件 | 职责 |
| --- | --- |
| AppComposition.swift | 持有当前 Services 和生命周期图，连接 UI bootstrap/retry/failure 端口；显式重试替换整个根作用域 |
| ServiceFactories.swift | 选择 Storage 运行工厂和数据库位置，创建原生实例、照片工厂、模型制品服务及 Agent 集成入口；注入延迟领域仓库接口 |
| ModuleRegistration.swift | 注册 storage → agents → native 的静态依赖与公开启停/失效接口 |

配置中的资源路径属于组合输入。照片容量/FIFO、Provider 事务、模型选择、页面控制、意图编码和结果转换属于模块；App 不在绑定闭包中复制这些逻辑。

## 生命周期与失败

✅ 只有 Scene active 开启服务接纳；inactive/background 仍立即失效。初始作用域在 inactive 仅等待 active，不将正常等待当作启动失败。系统在启动中离开 active 后，清理成功的 suspended 图在下一次 active 由组合根停止并重建；一个替换任务合并重复事件；结束时按最新前台状态检查是否仍需恢复，不积累重建队列，不重放业务操作。启动错误和清理错误仍通过现有错误端口显示，手动重试规则保留。


StorageContainer 在自己的后台启动任务中完成后端打开、迁移和恢复，成功后才发布仓库；App 通过 start 等待结果并按依赖顺序开放业务接纳。模块内部服务工厂返回明确端口；不存在全局 App 查找。

一个替换任务，没有重试队列；重复重试合并。旧图停止完成后才创建新实例和 scopeID。清理失败保留旧图和错误，不启动替代原生所有者。持久化设置/记录和媒体由仓库保留，不重放操作。

[App](../README.md) · [生命周期](../Lifecycle/README.md) · [Agent 集成](../../Agents/Support/README.md) · [Action 集成](../../Actions/Support/README.md)

✅ Services 持有 storage: StorageContainer；工厂持有独立 ApplicationContainer 并选择根 URL，注入领域仓库提供器。注册实际 storage.start/stop 与 storage → agents → native 依赖；不调用 SQLiteRepositories、FileManager 或恢复。

## 待实现

- 多窗口实例隔离；强制中断非合作依赖仍不可用。

## Storage 依赖

✅ 存储访问使用独立的 State、Cache、Database 和 Files 接口；App 注册根实例，消费者通过构造器获得所需能力。存储容器不接管本目录的业务验证、执行和完成语义。

AppStorage 目标只编译 Composition/ApplicationContainer.swift，使用 FactoryKit 实例内缓存；业务目标不导入 IoC。Services 持有注册容器和 StorageContainer，连接所需子接口。模型后台事件只转交 ArtifactServices；存储停止前先加入其制品清理。
