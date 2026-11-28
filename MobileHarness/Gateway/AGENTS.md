# Gateway 开发规范

适用于本目录及其子目录。先读[仓库规则](../../AGENTS.md)、[模块设计](README.md)和[传输契约](Input/README.md)。

## 职责归属

| 位置 | 开发职责 |
| --- | --- |
| 模块根 | GatewayContainer 的配置、接纳、隔离观察范围、生命周期和结构化失败。 |
| [Input](Input/README.md) | 通用端点、信封、Send、Request/Reply、事件订阅、容量、顺序与取消。 |

## 开发边界

- 保持 Gateway 可独立编译，只使用系统库。端点身份、协议描述符、路由参数和 Sendable 负载由使用端提供。禁止导入、识别或特判 Agent、Action、App、基础 SDK、具体角色、业务路径或信号类型。
- 端点所有者定义并构造业务 Signal 和负载，负责业务语义校验、授权和结果解释。Gateway 只处理通用传输信封及已注册的类型、版本、字节预算和时限。禁止替业务方包装、翻译或补齐 Signal 数据，禁止合成业务回执。
- 定向 Send 和 Request 共享接纳容量，可以在同一端点和频道并发。调用方所需的提交顺序用其自有等待或显式有界发送器实现。禁止把 Action Channel、Tool 并发策略、任务队列或 ReACT 编排写进 Gateway。
- Pub/Sub 保持每频道、每订阅者的有界 FIFO。发布确认代表本地接纳。不得把发布确认当作订阅者执行成功，不为迟到订阅者自动重放，也不因单个旁支失败重发已接纳分支。
- 传输层变更应审查重复绑定、代际替换、嵌套请求环、取消和清理。使用已注册端点及原回执关联，禁止向继任端点投递旧代结果。新增排队必须有上限和明确的拒绝策略。

## 示例

接收端所有者用同一版本描述符注册处理器并回送实际返回值。测试使用 Int 作为不透明负载，在 Gateway 侧验证类型、原样交付和回执，业务计算写在注册的处理器中。完整例子见 [GatewayContainerTests](../../Tests/Gateway/Output/GatewayContainerTests.swift) 的 `gatewayRequestRepliesWithoutSourceInboxAndRejectsUnknownProtocol`。新增视觉事件或 Action 执行结果时，在相应业务端定义和组装负载，App 用公开端口接线。
