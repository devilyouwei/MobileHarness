# Routing · 输入路由

用途：决定输入投递到哪些 Agent。设计目标：支持逻辑、JEV 和轻量 Agent 混合路由，保持业务规划在 Agent 内。

- ✅ `SignalRouter.swift`：可注入的路由协议；过渡期参数仍为 AgentInput。
- ✅ `LogicRouter.swift`：当前确定性默认路由到 Assistant。
- ✅ InputGateway 对目的地去重，允许单个目的地失败而不阻止其余投递。
- ❌ `JEVRouter.swift`、`AgenticRouter.swift`：暂无调用场景，未建立。
- ❌ 基于新 Signal 的类型、来源、上下文和优先级混合路由。

维护约定：修改本目录代码、文件或子目录时同步更新此 README；✅ 表示已实现，❌ 表示尚未实现，不用空实现占位。
