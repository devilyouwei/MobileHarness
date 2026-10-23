# Platform Core — 通用原生生命周期工具

## 职责与边界

PlatformKit Core 只依赖 Foundation/Synchronization/UIKit，不识别 Agent、Gateway、Action、UI 展示或应用业务。业务所有者注入读取、发布及错误报告回调；工具不选择领域反应。

## 接口与运行契约

资源观察的业务寿命不属于本目录；此处不实现采样、指纹比较或 Gateway 发布。

✅ NativeBackgroundAllowance（iOS）持有一个系统后台额度和一个到期任务，替换先结束旧额度；OS 到期或明确 end 均幂等释放。它只为短期清理/重新关联提供额度，不保证后台模型或物理设备执行。

## 直接关系与生命周期

NativeInputBroadcast provides bounded independent observation. Capture-generation fences belong to the concrete Audio/Vision input sources. Native device shutdown remains owned by Audio, Vision and Connectivity; this directory owns no business sampler or Gateway publication.

[PlatformKit](../README.md)

## 待实现

❌ 非合作原生操作的强制中断和物理设备停止确认不由这些工具实现。

✅ NativeInputBroadcast 只提供原生值分发，最多 16 个订阅者；latest 每订阅者保留一项并计数替换，ordered 每订阅者 64 项、溢出只终止该订阅并保留明确错误。finish 关闭当前全部订阅；不启停设备、不提供 Signal 或业务重放。

✅ 音频围栏和单源容量由 Audio/MicrophoneCapture 拥有，相关回归验证实际音频源；本目录不再提供额外的采集广播围栏。


## Direct container contract

Native data/observation capabilities remain independent of business and transport modules. Capture control stays with execution owners; read-only observation never requests permission or opens a device. Current cross-module ownership is defined by the [overall design](../../README.md).
