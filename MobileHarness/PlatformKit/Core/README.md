# Platform Core — 通用原生生命周期工具

## 职责与边界

PlatformKit Core 只依赖 Foundation/Synchronization/UIKit，不识别 Agent、Gateway、Action、UI 展示或应用业务。业务所有者注入读取、发布及错误报告回调；工具不选择领域反应。

## 接口与运行契约

✅ ResourceObservationWorkflow 持有一个采样 worker 和最新前台状态，没有待处理事件队列。指纹最多 65536 字节，失败文本最多 2048 字节；只在成功接纳后记住读取值。取消期间不提交迟到值，失败可显式重试；shutdown 关闭接纳、取消并加入 worker。观察结果不授予执行权限。

✅ NativeBackgroundAllowance（iOS）持有一个系统后台额度和一个到期任务，替换先结束旧额度；OS 到期或明确 end 均幂等释放。它只为短期清理/重新关联提供额度，不保证后台模型或物理设备执行。

## 直接关系与生命周期

AgentBindings 注入原生事实读取与 Gateway 发布接口；ActionBindings 使用短期 OS 清理额度。调用者持有实例并显式启停；页面不拥有这些根任务。各设备原生停止仍由 Audio、Vision、Connectivity 实现。

[PlatformKit](../README.md)

## 待实现

❌ 非合作原生操作的强制中断和物理设备停止确认不由这些工具实现。

✅ NativeInputBroadcast 只提供原生值分发，最多 16 个订阅者；latest 每订阅者保留一项并计数替换，ordered 每订阅者 64 项、溢出只终止该订阅并保留明确错误。finish 关闭当前全部订阅；不启停设备、不提供 Signal 或业务重放。

✅ NativeInputSession 为回调广播提供可同步关闭的单代围栏，无转发任务/额外队列；finish 与 send 串行，关闭后迟到回调不能向复用广播发送数据。
