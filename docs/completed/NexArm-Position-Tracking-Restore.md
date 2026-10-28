# 恢复 Photographer 位置角度跟踪

日期：2026-10-27。用户要求取消速度模式，恢复 main-sh 合并后的有限角度目标，并核查 PlatformKit 限位。

## 历史与问题

b398fd9e 合入 ADR0215 单目标位置指令，451b9bea 合入 ADR0216 肩肘水平准备。9ff32177 后改为寄存器33=1、寄存器46闭环速度，当前 main 包含4bb3296d的4号方向位反转，以及fe73223e的保持速度直到目标静止。全分支历史另有377b5470/86017d6e，但 merge-base 核对确认它们不是当前 main 的祖先，不能将其当作已合入代码。当前 main 的算法包含软件积分估计和手机端停止，不具有设备端位置限位保证。用户报告反向、过载和损坏；代码可以证明速度路径缺少位置边界约束，不能仅凭历史确定具体损坏原因。

PlatformKit 的 positionLimits 为六轴 [210…3826,200…3800,968…3200,728…3218,908…3128,1118…2828]。move 和位置包准入使用该范围；旧速度包仅约束速度幅值。它们是主机编码边界，不是舵机硬件限位配置，当前代码没有烧录设备最小/最大角度或过载保护。原始 exchange/write 还允许手工构造寄存器写，需同步堵住速度模式旁路。

## 实施计划（代码修改前记录）

- Actions/NexArm/Tracking/NexArmAimCommand.swift 恢复 9ff32177 第一父提交的位置算法，适配当前 FunctionContracts import：12 count 死区，有限前瞻且限幅，速度参数10…600仅为位置动作的运行速度，首包保留肩肘水平准备。最新未接纳目标覆盖旧目标，发送成功才提交状态。删除速度积分、方向位、扭矩/模式切换和退出寄存器恢复。
- NexArmControlService 保留根拥有、资源许可、代际、新鲜度、取消加入和30ms准入轮询；只发送有限位置包，结束仅关闭 live session，不再在取消后补发目标或寄存器命令。
- PlatformKit/NexArmMotorCommands 删除速度、模式、扭矩写构造 API；NexArmProtocol 的 live/observed 仅准入合法位置写，新增统一寄存器写校验，所有 USB/BLE 发送路径均拒绝非法CMD3/CMD131（包括手工构造速度/模式/扭矩包及越限位置）。保留只读查询和既有非寄存器协议能力。删除 restoreLive 及所有替身实现。
- 测试：恢复位置算法用例，覆盖正负方向、极限/前瞻钳制、未知/速度/模式/扭矩寄存器拒绝、原始发送前共享校验；蓝牙替身覆盖单目标位置包、不重复写、取消后不补发、资源与代际隔离。更新受影响测试替身。
- 文档：同步 Tracking、NexArm、PlatformKit/Connectivity/NexArm、Photographer、总体 README 和测试 README；ADR0217 标为历史且被本次决定替代，保留历史试验。所有未完成验收只记录 docs。

## 验证与边界

运行 scripts/check.sh 和 scripts/build-ios.sh；不连接或控制真实机械臂，不安装新版本，除非用户另行要求。既有会话/位置模式是运行前提；源代码回退不会自动修复硬件中已持久化的速度模式或损坏，需要单独确认设备配置。主机位置范围不等于碰撞、载荷、电流或温度保护，当前没有这些传感/硬件保护证据。

状态：代码恢复及要求的自动化检查完成；独立实机验收尚未执行。

## 实现与验证结果

已恢复9ff32177第一父提交的位置算法，保留当前模块边界与FunctionContracts依赖。生产跟踪中不存在速度积分、方向位编码、模式/扭矩/速度寄存器写和取消后恢复发包；restoreLive接口及全部替身已删除。USB send与BLE perform统一校验原始CMD3/CMD131，live/observed准入也只接受有界位置包。Photographer的姿态选择与base/pitch角度目标接口未改变。

2026-10-27验证：

- scripts/check.sh退出0：876项普通集成测试、221项隔离运行时测试及其他包测试通过，边界、格式、6项Python测试与plist检查通过。无新增失败。日志 /tmp/mh-position-tracking-check.log。
- scripts/build-ios.sh退出0：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero四个Simulator scheme均BUILD SUCCEEDED，最终资源验证通过。日志 /tmp/mh-position-tracking-ios.log。
- 新增正负目标方向、两轴边界前瞻钳制、六轴越界与速度/模式/扭矩包拒绝测试通过。恢复的历史位置死区、速度参数、提案替换与肩肘准备用例通过。蓝牙替身确认同目标不重发、取消后无追加包、接管资源与代际隔离。
- git diff --check通过，检查当前源码及文档无过时速度路径引用；ADR0217保留为历史。
- 未向真实机械臂发包，未安装本次版本。此前安装的2026102701仍包含旧速度算法，不能视为此恢复的实机验收。设备是否处于位置模式、机械零点/硬件角度限位/载荷及过载保护需独立确认；本次不自动重写设备配置，也不能从软件回归推断反转或烧毁的唯一物理原因。

