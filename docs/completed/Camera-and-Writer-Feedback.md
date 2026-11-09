# 相机设置、预览及 Writer 回馈

- Camera.Capture.configure 仅接收显式字段的更新。Actions Support 定义更新值，CameraCoordinator 在独占配置段内用最新设置补齐，沿用 CameraCaptureConfiguration 的原生事务和失败回滚。无字段时成功且不写入硬件。同步相机、公共契约和 Photography 的说明。
- Camera.Capture.open 等待窗口与原生预览就绪后返回结构化完成，失败仍传播。CameraCaptureWorkflow 复用相同入口并继续仅观察照片或录像结果。移除成功窗口回执及其查询端口，窗口操作使用 ui.windows。开预览后切镜头按同一 Camera Channel 顺序执行，打开失败时后续镜头操作仍由实际相机状态校验。同步 Action 描述、Photography 示例和评估夹具。
- Writer 使用既有角色灵动岛展示接纳、补充、取消、进度、追问及终态原文。终态短时展示并由 Writer 岛发布者拥有单个可取消的结束定时器，新委派覆盖旧展示。Assistant 的可信任务消息只更新状态和持久消费标记，无模型轮次或语音回合。追问保留绑定到当前委派的 interactionID，终态保留持久投递与独立运行时退休。Writer 使用绑定注册身份的返回型 AgentMessaging，删除该角色的投递回执邮箱。
- 委派和发往 Writer 的补充/取消成功后返回结构化完成。拒绝或传输异常仍可观察。前台控制保留现有行为。更新 Assistant、Writer、共享通信及总体设计说明。
- 验证相机局部参数和开预览完成/失败、Writer 岛终态及任务身份与去重、回馈期间 Assistant 无额外模型请求。运行 scripts/check.sh 和 scripts/build-ios.sh。

普通运行进度留在 Writer 自己的 State、窗口和灵动岛。跨角色的 task.progress 仅传接纳及追问，移除逐轮进度事件与通信字段。实际请求编号与尝试信息继续用于 Writer 自己的展示和历史。验证创作期间不发送普通进度或语音，追问及终态仍可递送。

## 2026-11-09 验证

- 14 项专项测试通过。其中 Writer 回馈场景覆盖 20 种组合，核对重复和迟到通知、追问回复、终态消费与 Assistant 模型轮次数。相机用例覆盖省略设置、预览完成和权限拒绝。灵动岛用例覆盖终态文字、撤下及保留语音活动。
- scripts/check.sh 首轮的主集成套件有一项机械臂跟踪断言失败。该用例单独复测通过，重跑整个主集成套件的 1108 项测试通过。LiveRuntimeTests 的 228 项通过。原生 Metal 相机呈现用例仅有启动记录。
- scripts/build-ios.sh 的四个 iOS 模拟器方案通过，校验了 34 项 Agent 和 Skill 资源及内嵌 Live Activity。真机交互待验收。

## 2026-11-09 真机安装

签名 Debug 构建 `0.1.0 (2026110905)` 通过严格签名、34 项 Agent 和 Skill 资源及 Live Activity 打包校验。已原位安装到 iPhone 17 Pro，安装回执序号 6432。独立读取设备应用清单确认版本从 `2026110904` 更新为 `2026110905`。本次证据覆盖安装与版本核验。
