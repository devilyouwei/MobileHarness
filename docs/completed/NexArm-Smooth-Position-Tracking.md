# NexArm 位置跟随平滑与设备约束归属

## 需求与边界

保持有限位置模式，提高跟随连续性；目标更新允许提高 Hz，但必须有通信硬上限，不能积压蓝牙指令。设备位置、寄存器参数和通信限制统一属于 PlatformKit，Photographer 保留视觉跟随策略，Actions 保留几何、资源和执行生命周期。此次不连接、驱动或安装真机，不修改硬件模式/保护寄存器。

## 实施设计（代码前计划）

- `PlatformKit/Connectivity/NexArm/NexArmMotorCommands.swift` 在现有文件定义公开设备约束：六轴范围、编码器范围、原生速度/加速度、默认参数、连续位置控制速度上限及手动规划导数限制。提供推荐位置更新间隔 50 ms（20 Hz）和 BLE 共用最小写间隔 30 ms（约 33 Hz）。编码器和包验证使用同一份限制。
- `NexArmProtocol.swift`、`NexArmBluetooth.swift` 使用上述约束；保留所有生产者共享的单信用发送预算、原生可写/MTU/ACK 门控、无积压包队列及超时失败。限制不依赖 Photographer 是否限频。
- `Agents/Photographer/PhotographerTrackingPolicy.swift` 消费基础模块的更新间隔，输出由 5 Hz 提升至最多 20 Hz；滤波系数随观测时间变化，积分按实际时间推进，长间隔至多积分 0.2 秒。保留画面中心死区、构图角度窗口、拒绝输出不推进目标、目标丢失不盲目外推。
- 检查执行链后补充：`PhotographerExecutionSession.swift` 原跟踪派发队列容量 8 会在慢执行时追赶旧目标，改为正在执行一个、待执行最新一个；替换仅限同一跟踪会话的未执行目标，公开饱和计数记录被替换数量，detach/shutdown 清空单槽并取消加入 worker。普通摄影事务不采用目标覆盖语义。补充真实角色/Gateway 派发的慢消费者回归。
- `Actions/NexArm/Tracking/NexArmAimCommand.swift` 将目标门槛由 12 count 缩小为 3 count；保留单次步幅内的有限前瞻及硬范围钳制，运行速度根据已接纳目标间的实际时间计算，避免更新频率提高后速度反而降低。只有实际接纳才提交目标/采样历史，未发送目标可被替换。静止目标不重复发送。
- `NexArmControlService.swift` 跟踪 worker 按设备推荐间隔处理最新单槽目标；手动 worker 引用 SDK 最小间隔。资源、取消和会话所有权保持现有设计。
- `Actions/NexArm/Motion` 的参数校验、手动规划和诊断位置编码，以及根行为适配、Support 请求、Connection 入口的默认值引用 PlatformKit 设备约束；业务构图、手势配方、归位几何、经验到位预算不下沉到基础模块。
- 更新 PlatformKit/Connectivity/NexArm、Connectivity、PlatformKit、Photographer、Actions/NexArm/Tracking、Motion、NexArm 及总体 README，说明依赖方向、实际频率上限、队列边界及物理验收限制；不创建目录。

## 验证与交付条件

增加可观察回归：高频输入输出节流、不同采样率的相同时间位移、过时/重复时间不推进、卡顿不补发/不放大位移、未接纳目标不污染前瞻、细小目标与反向/边界、速度上限与非法原生参数拒绝。复用混合生产者 BLE 预算/原生背压/取消测试。

运行 `./scripts/check.sh`、`./scripts/build-ios.sh`、diff 格式和文档链接检查。自动化与构建不能证明实物丝滑、物理限位、固件位置模式或堵转保护；这些需独立真机验收，不宣称已经完成。

## 完成记录（2026-10-27）

实现、文档和软件验证完成；设备限制位于现有 PlatformKit 文件，没有新增目录、依赖或模式写入。

- 15 项目标/限位/手动专项通过，1 项 USB 实物测试按显式开关跳过；3 项派发/拒绝专项通过。
- `./scripts/check.sh` exit0：普通集成分组报告 882 项，运行时分组报告 221 项；架构/模块边界、格式、Python、其它 Swift 包及 plist 检查通过。显式开关控制的真实模型/服务/原生专项及机械臂实物测试仍跳过，不能算实物通过。
- `./scripts/build-ios.sh` exit0：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四 scheme 通过，最终应用 Skill/函数资源校验通过。
- diff 格式和受影响文档的本地链接检查通过。证据见 [验证历史](../validation/Validation-History.md)。

以上软件验收阶段未安装本版到手机、未发送硬件运动指令。20 Hz 是目标更新上限，实际随姿态产出和链路背压降低；实物平滑、负载/温升、固件模式和机械标定须独立真机验收。

## 后续真机安装（2026-10-27）

按用户后续要求，将包含本次优化的0.1.0/build2026102702原位安装到iPhone 17 Pro，保留应用数据。真机签名构建、资源校验、安装后版本查询和系统启动/进程存在确认通过。未执行机械臂动作验收；证据见[验证历史](../validation/Validation-History.md)。
