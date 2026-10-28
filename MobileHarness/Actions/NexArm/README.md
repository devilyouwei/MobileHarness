# NexArm — 业务函数与执行设计

## 职责与模块关系

拥有机械臂动作、连接业务、手动及跟踪执行。NexArmModule 统一注册函数；NexArmControlService 是连接代际、资源准入、工作模式互斥与任务取消加入的唯一协调者；独立的手动／跟踪状态保存各自规划。原生编码和链路属于 PlatformKit。

Gateway 通过注册函数调用本域，Agents 决定请求与策略，App 注入唯一基础能力和根生命周期。本域消费 FunctionContracts 及需要的基础能力，不导入 Agents、Gateway 实现或 App。全部域内源码由 Actions 单一目标编译。

## 目录与文件

| 文件 | 当前职责 |
| --- | --- |
| [NexArmActions.swift](NexArmActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [NexArmBehaviorAdapter.swift](NexArmBehaviorAdapter.swift) | 有限动作与跟踪调用的参数、报告及失败适配 |
| [NexArmControlService.swift](NexArmControlService.swift) | 连接代际、资源准入、工作模式互斥及所有任务取消加入 |
| [NexArmModule.swift](NexArmModule.swift) | 完整目录及复用同一工厂的部分目录投影 |

| 目录 | 责任 |
| --- | --- |
| [Connection](Connection/README.md) | 连接与控制状态由根控制服务拥有；本目录投影不把连接成功解释为电机到位 |
| [Motion](Motion/README.md) | 有限计划只在连接内执行器中接纳，不另设 Channel 队列 |
| [Tracking](Tracking/README.md) | 跟踪只保留最新目标，命令提案与实际接纳分开 |

[Support](Support/README.md) 仅维护跨业务能力共用的契约或算法。



## 接口与电机范围

目录包含十一项有限运动函数及一项跟踪发布函数。

| 地址模块 | 函数与参数 | 资源声明 |
| --- | --- | --- |
| NexArm.Motion | moveMotor：motor 1…6、target 0…4095；resetMotor：motor 1…6 | 选中电机 |
| NexArm.Motion | reset：无必填参数；shakeBase：cycles 1…3 | 电机 1…5 |
| NexArm.Gesture | nodHead：cycles 1…3 | 电机 4 |
| NexArm.Gesture | shakeHead：cycles 1…3 | 电机 5 |
| NexArm.Gesture | waveWrist：count 1…3；tiltWrist：direction left/right | 电机 1…5 |
| NexArm.Gesture | lookAround/celebrate/dance：cycles 1…3 | 电机 1…5 |
| NexArm.Tracking | aim：有限 base/pitch 弧度，均为 −4π…4π | 发布函数不持有电机资源 |

有限运动可选 speed 1…1400（默认 1400）、acceleration 1…254（默认 30）；未知键拒绝。target 在执行编码时进一步受设备电机范围约束。入口不接受时间、减速度、力矩、模式或校准参数。

运动请求以 GestureRequest 或注入闭包传递。有限动作要求新鲜反馈判定完成；aim 只确认最新目标发布，跟踪和资源持有属于根 worker。`NexArm.Tracking.aim` 接收 base/pitch 位置弧度，直接映射为有限编码器位置目标。单目标位置算法使用 3 count 死区，有限前瞻不超过本次已接纳目标步幅并钳制到 PlatformKit 六轴位置范围；根据实际采样间隔选择位置动作速度，最高速度与原生参数校验由 PlatformKit 提供。跟踪 worker 使用 SDK 的 50 ms 更新间隔，手动 worker 使用 SDK 的最小 BLE 写间隔；原生链路最终执行连接级限频与背压。首次接纳包包含肩/肘水平准备，后续只寻址1/4，不操作5/6。停止只关闭并加入 live session，不再补发目标、扭矩、模式或持续速度指令。收到包不等于实际到位；设备须预先处于位置模式。


## 资源与预算

NexArmRegistration 将资源命名为 `nexarm.motor.1` 至 `.6`。nod/shakeHead 只声明相应电机，move/resetMotor 解析指定电机，其余有限动作声明 1…5。无效单电机参数不能据空解析结果取得运动授权，函数参数校验仍会拒绝执行。

有限函数使用 dynamicTimeout。注册前按速度/加速度、最大合法行程、动作段数估算：段内电机预算取最大，段间求和，每段包括一秒发送准入余量，整体再加入五秒准备/清理余量。实际逐电机 deadline 由控制器按已获得的位置计算。预计时间不插入最低等待，预算不包含调度排队。aim 使用共享的默认 30 秒发布预算。


## 完成、状态与失败

Support 将动作转换为有界电机计划。整臂动作及归位只涉及 1…5；motor 6 只能由显式单电机路径操作，resetMotor(6) 必须配置软件 home。普通 passiveBLE 归位参考位置与跟踪 rest 是独立状态，不以发出的目标冒充测量值。

新鲜的发送后反馈进入容差即完成；稳定未到位、运动超时、反馈丢失、断连、发送/准入/反馈异常各有明确结果。普通未到位或电机超时保留结果并执行后续段；取消停止后续写入，清理观察会话。通用反馈算法和数值位于 PlatformKit，动作结果与执行状态位于对应业务目录。

Controller 提供 motorResults 与 revision；宿主将逐电机结果写入本次 invocation 的报告端口，并保留后续异常。单个控制器一次只接纳一个物理执行，即使上层资源集合不相交也不会自动获得控制器内并行执行。

本域没有另一套 Channel 队列或 Bluetooth 重连策略。取消加入软件清理不证明设备物理停止，已有运动不会通过隐式补偿或重发撤销；手动/跟踪操作的持续寿命与替换由宿主负责。

[Actions 设计](../README.md) · [公共函数契约](../Support/Contracts/README.md)

## Container 上下文

NexArmControlService.contextSnapshot 从当前连接、控制器、跟踪与反馈健康状态提取 connected/controlAvailable；不复制到Storage。既有连接事实订阅继续服务角色生命周期，模型读取不产生订阅或设备动作。

NexArm通用设备参数、允许误差、位置反馈观察、经验行程估算与原生恢复分类/预算由 PlatformKit 拥有；Actions 仅消费这些能力并拥有动作目标、资源、执行报告、设备选择及业务生命周期协调。硬件错误保持SDK类型，上层仅适配展示与动作结果，基础模块不依赖业务模块。

Motor Actions expose absolute encoder targets or relative encoder-space degrees. Actions acquires the fresh starting measurement and owns the move; PlatformKit owns conversion and final target bounds. RobotInteraction teaches axis selection and composition using these declarations.
