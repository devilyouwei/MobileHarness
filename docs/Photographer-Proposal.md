# Photographer proposal — Camera motion and composition

Status: the camera session now dispatches aim and the verified BLE link writes the five-axis packet. Composition and physical tracking acceptance remain proposed.

Goal: enable a robot-mounted phone to frame subjects, track movement and choose camera motion based on user intent and shared perception. Photographer decides aim from shared perception and requests an authorized Tool. The camera session now sends that Tool over verified BLE. Device-side stop acknowledgement and disconnect recovery are still outstanding, so a sent packet is not a completed physical motion.

Current status: [VisionPerception](../MobileHarness/Agents/VisionPerception/README.md) owns pose inference and UI.showPose skeleton feedback. [Photographer](../MobileHarness/Agents/Photographer/README.md) subscribes to `vision.pose` and emits `Robot.aim`. The camera session enables that control and sends the packet over verified BLE. No Wi-Fi socket is opened. See [ADR 0102](adr/0102-photographer-aim.md).

Aim already consumes `vision.pose` and does not own YOLO or skeleton rendering. The camera session sends the five-axis packet when BLE control is ready. Composition, motion limits and disconnect recovery still need a defined task. A sent packet is not measured arrival.


## 输入、订阅与输出边界

实线是已经接通的瞄准订阅和蓝牙写出。虚线不再表示这条写出；构图和真机验收仍未完成。

```mermaid
flowchart LR
    Vision[VisionPerception] -->|vision.pose| OG[OutputGateway / InputGateway]
    OG -->|subscribed| Photographer[Photographer]
    Photographer -->|Robot.aim when enabled| Output[OutputGateway]
    Output -->|verified BLE write| Device[NexArm]
```

| 项目 | 当前状态 | 未来接入要求 |
| --- | --- | --- |
| 感知订阅 | ✅ 订阅 `vision.pose` | 不能直接读取 VisionPerception 的内部状态。 |
| 用户任务 / 设备反馈等其他输入 | ❌ 无协议或实现 | 实际业务确定后声明 contract 与来源，再定义数据结构和处理策略；当前不能声称接收这些输入。 |
| 运镜瞄准 | ✅ 内部 `Robot.aim` 和五轴包；相机会话会经已验证蓝牙写出；夹爪不写 | 构图和真机跟踪验收仍未做。链路收下指令不等于手臂已经到位。 |
| 共享观测 / Agent 定向消息 | ❌ 无 publications / sends | 有具体消费者后再定义，不隐式拥有发送权限。 |
| 骨架 UI | ✅ 已由 VisionPerception 实现 | `UI.showPose` 不属于 Photographer。 |

现有姿态数据的结构、容量和新鲜度约束以 [VisionPerception 输入输出契约](../MobileHarness/Agents/VisionPerception/README.md#输入订阅与输出契约) 为准；它不提供 tracking ID、深度、机器人状态或运动命令。

未来消费者必须接受最新状态可能跳帧、空 people 表示无人、观测可能过期的事实。手机视觉刷新不提供硬实时控制保证；不能把感知数据直接当作物理控制指令。
