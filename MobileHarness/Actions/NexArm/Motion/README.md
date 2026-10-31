# NexArm/Motion — 业务能力与执行

## 职责与关系

有限计划只在连接内执行器中接纳，不另设 Channel 队列。手动输入保留六电机最新值；只有实际准入后提交规划状态。取消停止后续写入并加入反馈观察清理，已接纳运动不自动重发或补偿。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [GestureActions.swift](GestureActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [MotionActions.swift](MotionActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [NexArmActionController.swift](NexArmActionController.swift) | 连接内有限计划执行、反馈完成与软件归位 |
| [NexArmCompositeActions.swift](NexArmCompositeActions.swift) | 组合动作几何与 IK 编译 |
| [NexArmJogPlanner.swift](NexArmJogPlanner.swift) | 手动速度、加速度与加加速度整形，提案／接纳分离 |
| [NexArmJogSession.swift](NexArmJogSession.swift) | 手动输入与已接纳规划状态 |
| [NexArmJointCommand.swift](NexArmJointCommand.swift) | 关节目标映射及诊断几何 |
| [NexArmMotionPlan.swift](NexArmMotionPlan.swift) | 有界运动计划及SDK观察器兼容别名 |
| [NexArmRegistration.swift](NexArmRegistration.swift) | 有限动作的资源集合与动态预算 |
| [NexArmSimpleActions.swift](NexArmSimpleActions.swift) | 点头和摇头的有限电机配方 |

设备 ID、编码器/目标范围、寄存器参数、连续位置速度与手动规划导数上限均引用 PlatformKit `NexArmDeviceLimits`。手动包通过 SDK 位置编码器构建；诊断 aim 同样使用连续位置速度上限。手势/构图几何与动作编排留在本域；设备容差、位置观察和经验行程预算由 PlatformKit 提供，不写设备保护配置。

## 几何、归位与计划约束

| 源码 | 算法与边界 |
| --- | --- |
| NexArmSimpleActions | nod 电机 4、shakeHead 电机 5；中心帧加每轮五个扫动帧，振幅分别 380/500 count |
| NexArmCompositeActions | 有限 XYZ/姿态配方，前后包含 home；NexArmArmPlan 把几何经设备 IK 编译为只含电机 1…5 的写入 |
| NexArmMotionPlan | 1…20 步，锁定集合非空且位于 1…6；每步目标在集合内，全部目标并集必须等于锁定集合 |
| PlatformKit.NexArmMotorProfiles | 本域消费SDK电机容差及经验行程预算 |
| NexArmRegistration | 调用前资源集合和整体动态预算解析 |
| NexArmJogPlanner / JointCommand | 手动速度整形及关节目标映射 |
| NexArmAimCommand | 单包跟踪、死区、有限前视和准入后提交 |

普通 passiveBLE 整臂归位使用参考 count `[2048,2087,1198,1238,2048]`；显式软件 motorHomes 用于单电机 reset。其它归位路径可由设备 IK 的 home `[200,0,200,0,0,0]` 解析。跟踪 rest 独立为 `[2047,2087,1984,2045,2048]`，不等同于普通 home。

IK 表最多 64 个几何键，检查回包地址/命令/长度、请求姿态及五个关节范围。几何 CMD8 只是待编译意图；实际运动发送使用单电机 CMD3 或同时电机组 CMD131，不将夹爪带入整臂配方。计划 frame.milliseconds 限 1…10000，作为帧信息保留；反馈执行器不以名义帧时间强制等待到位。

## 逐电机反馈完成算法

execute 为一个有限计划持有观察 session 和 lockedMotors，逐段发送并跟踪每个电机。发送前可读取已有最新反馈作为预算起点，但只有 sample 时间不早于本次发送起点、且 sequence/time 更新的反馈能完成新运动。

通用容差、反馈配置、位置观察算法及经验行程预算由 [PlatformKit NexArm](../../../PlatformKit/Connectivity/NexArm/README.md#generic-motor-feedback) 唯一维护。`NexArmSegmentTracker` 是 SDK `NexArmPositionObservation` 的兼容类型别名，本域不复制判定实现。执行器逐电机调用观察器，并将其 arrived/unreached/timedOut 转为动作结果。

观察/未准入重试间隔为 20 毫秒，单段发送准入上限一秒。默认反馈缺口上限两秒，丢失或断连后将后续段标为未启动并禁止继续写入。普通目标未到位或电机 deadline 到期不丢掉结果，继续后续段。NexArmMotorCompletion 可指定合法容差、稳定/反馈时间和 timeout，实际稳定窗口取策略与估计的较大值。

## 状态、失败与清理

NexArmMotorResult 保存 step/motor/target/observed/failure/started；最多 20 步乘六电机的结果量由计划边界推导。控制器保留最早真实执行异常，并加入观察会话关闭后返回；cancelled 停止后续发送，剩余叶子记为未启动取消。

失败分为 targetNotReached、timedOut、feedbackLost、disconnected、sendingFailed、admissionFailed、feedbackFailed、cancelled。发送返回未准入时可在一秒窗口内重新提议，已经接纳的运动不自动重放。unreachedSegments、lastFailure、motionFailure 保留诊断分类；它们不是自动重连指令。

有限 execute 开始时重置 faulted，不把旧失败永久封锁为新的运动准入。独立 aim/readState/verifyCompatibility 路径对 faulted 有限制；recoverState 是只读测量恢复，加入稳定样本检查后清除该状态，不重发运动。

[所属域设计](../README.md) · [Actions 模块](../../README.md)

## Relative motor requests

`moveMotor` accepts exactly one of absolute `target` (encoder counts) or signed `deltaDegrees` (relative encoder-space degrees), plus native speed/acceleration. The executor holds its busy ownership across a fresh CMD11 exchange, SDK conversion/limit validation and finite feedback-observed execution. Read failure or an illegal final target produces no motion; no home/cached fallback, clamp or wrap is used. Canonical declarations expose axis anatomy and count limits. Base-right increases counts in the current arm convention.

## Passive motion observation

NexArmActionController.stateSnapshot reads busy/faulted, locked axes, active per-step targets and existing motor results/revision. It sends no packet. Targets are declared during the current execute step and cleared on exit; they are never measured positions. Retained results distinguish actual arrival, timeout, feedback loss, cancellation and unsent admission failure. Motor result Codable support preserves its explicit domain fields and failure enum.

stateSnapshot() async throws returns only the motion node with targetCounts, execution instrumentation and six axis path references. stateReaders() builds weak-owner exact capabilities; a selected motor reader samples that axis record directly without reading a parent snapshot. These reads do not change motion, cancellation or result ownership.
