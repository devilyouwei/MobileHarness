# App 开发规范

适用于本目录及其子目录。先读[仓库规则](../../AGENTS.md)、[模块设计](README.md)及本次接线涉及的模块规范。

## 职责归属

| 位置 | 开发职责 |
| --- | --- |
| [MobileHarnessApp](MobileHarnessApp.swift) | 应用入口、根视图挂载和系统场景事件转发。 |
| [Composition](Composition/README.md) | 构造唯一作用域根，注入公开端口，维护生命周期依赖，适配 UI 与模块公共接口。 |
| [Lifecycle](Lifecycle/README.md) | 通用启动、回滚、替换、系统事件和停止机制。AppLifecycle 保持目标独立。 |

## 开发边界

- 由作用域组合根统一注册和缓存模块根。FactoryKit 别名指向已有所有者，禁止为视图、Action、Agent 或适配器创建第二份根、连接或存储。
- 装配层只构造、绑定、转换结构化值和转发生命周期。禁止把动作校验、角色决策、ModelKit 选择策略、Signal 业务载荷组装或逐帧数据处理放进适配器。业务能力缺口由拥有模块补齐。
- 保持构造和启动可区分。在依赖就绪后开放上游接纳，在替换或启动失败时加入逆序清理。保持旧作用域的原生端口有效到清理完成，用代际或作用域身份隔离迟到回执。
- 页面和 scene 的可见性可以驱动装配层转发的生命周期请求。禁止在页面出现时独立启动模块、把视图消失当作全局取消，或以读取诊断 State 触发启动。

## 示例

连接底层事实时，由 App [组合装配](Composition/README.md)把 PlatformKit 的系统状态转换为 UI 定义的只读值。采样归 PlatformKit，布局归 UI。新增接线时测试同一作用域实例、失败回滚和停止顺序，参见 [App 测试](../../Tests/App/README.md)。
