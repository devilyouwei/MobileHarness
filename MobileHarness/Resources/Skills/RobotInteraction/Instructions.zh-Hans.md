## 机械臂互动

### 准入
CURRENT STATE 的 actions.robot 须显示 availability=available、connected=true 且 controlAvailable=true。满足条件即可按请求执行。否则说明实际阻碍，禁止运动、归位或恢复。查询不能覆盖阻碍。只支持电机 1–6，motor9 或 target5000 无效。

### 电机和单位
1 底座偏航，2 肩部抬升，3 肘关节，4 腕俯仰（nodHead），5 腕滚转（shakeHead），6 夹爪位置，当前装有吸盘。
从背后面向前方观察，底座的正 deltaDegrees 向右，负值向左。其他轴需要明确计数方向。moveMotor 的 target 是绝对编码器计数，deltaDegrees 是相对角度，只能提供一个。执行方读取实际位置并检验范围。不得猜当前计数或零点，也不得截断、回绕或修补无效值。
一圈 4096 计数，+90° 约 +1024，-45° 约 -512，+22.5° 约 +256。相对角度直接传入。speed 和 acceleration 是原生位置模式参数，以声明范围和默认值为准。请求绝对角度须先确认零点。

### 示例与结果
resetMotor 归位单轴，resetArm 不归位夹爪。演出手势收尾会归位，moveMotor 留在目标。机械臂按顺序执行。将所有已知且无条件的步骤放在同一响应，避免补加归位。
「底座右转 90 度」→ <moveMotor motor="1" deltaDegrees="90"/>
「底座左转 45 度，速度 400」→ <moveMotor motor="1" deltaDegrees="-45" speed="400"/>
「1 号到 3072 计数」→ <moveMotor motor="1" target="3072"/>
「腕俯仰到 1500 计数」→ <moveMotor motor="4" target="1500"/>
「肘关节沿计数增加方向转 22.5 度」→ <moveMotor motor="3" deltaDegrees="22.5"/>
「只归位肩或腕滚转」→ 根据请求用 <resetMotor motor="2"/> 或 <resetMotor motor="5"/>。
「右转 90，再左转 45，最后归位」→ <moveMotor motor="1" deltaDegrees="90"/><moveMotor motor="1" deltaDegrees="-45"/><resetArm/>
「右转 90、腕俯仰 1500 计数、点头两次、左转 45、归位」→ <moveMotor motor="1" deltaDegrees="90"/><moveMotor motor="4" target="1500"/><nodHead cycles="2"/><moveMotor motor="1" deltaDegrees="-45"/><resetArm/>
「先说你好，再挥手」→ <wait>你好。</wait><waveWrist count="1"/>
「4 号绝对 90 度」→ 先确认零点。电机 3 的 900 计数低于 968；速度 2000 超过 1400，禁止发 Action。
「先右转 30 度，只有成功才点头；失败就停」→ 先只发 <moveMotor motor="1" deltaDegrees="30"/>，等真实结果。失败时报告并停止。wait 只排序，void 成功不自动继续。

受理和到达不同。失败时不自动重试、归位、重连或补偿，取消不倒转物理动作。不要用动作测试连接。
actions.robot.value 的连接、控制可用性、示教或跟踪、以及 positionsCounts 是独立事实。feedbackAgeSeconds 是单调时钟计算的回执年龄，连接且年龄不超过两秒方可标记 feedbackFresh。null 是未知，过时位置只代表历史。targetCounts 和 trackingTargetCounts 是目标位置。读取 State 不查询或移动机械臂。
