# Generic Application Lifecycle

## 职责与编译边界

ApplicationLifecycle.swift 独立编译为 AppLifecycle，只依赖 Foundation。它管理服务图，不实现语音、相机、蓝牙、配置或展示。ApplicationSystemDelegate.swift 仅由 App executable 编译，把 OS 回调原样转交 Actions 的 ModelDownloadBackgroundService。

## 公开接口

ManagedService 声明 id、dependencies、start、同步 invalidate、异步 foreground、stop。ApplicationLifecycle 提供 start、setForeground、waitForForeground、stop、状态/失败及 onFailure 端口。模块不依赖 AppLifecycle；组合根把模块现有方法绑定为描述。

## 状态、容量与顺序

最多 64 个静态服务；超限、重复 ID、缺少依赖或循环在任何启动效果之前拒绝。拓扑排序对相同输入稳定。根图不动态增加服务。

一个 startup、一个 shutdown、一个前后台状态 worker；无事件队列。前后台保留最新期望状态及一个必须完成的非前台清理锁存位；快速 active 不丢失或截断暂停。非前台遍历按逆依赖顺序完整执行，不被版本变化截断；过期的前台恢复遍历可以抢占。重复停止加入同一结果。已停止/启动失败的图不重新启动，显式重试由组合根创建新图。

## 前台启动与暂停

首次启动可在 active 前被请求，但没有服务开始前只等待前台，不把等待当作失败。Scene 失活在服务启动中仍立即失效、取消并加入回滚；只有由生命周期自身发起的取消且清理全部成功，进入 suspended 而不发布准备失败。清理失败或前台服务自身抛错仍保留原始及清理错误。suspended 图不能再次 start，必须停止后创建新作用域；停止唤醒等待前台的任务，不能遗留 continuation。

## 失败与清理

按依赖启动，成功后才记入 started。启动抛错或取消先清理可能部分启动的当前服务，再逆序停止已启动依赖；ApplicationLifecycleFailure 分别保留 primary 与每个 cleanup error。迟到的启动返回必须再次检查取消/关闭/前台状态，不能发布 running。正常系统暂停且清理成功时抛 CancellationError 并进入 suspended，不设置 failure 或调用 onFailure；服务自己在前台取消仍是明确失败。

后台同步调用所有 invalidate，先关闭原生接纳，即使 startup 正在 await。随后加入异步前台切换。stop 同步失效并取消 startup/scene worker，加入它们后逆序停止服务。所有停止都会尝试，失败保留并向调用方传播；取消请求不证明物理停止。启动回滚中的清理失败也保留到终止结果，stop 不能将未确认清理改判成功，组合根因此拒绝创建替代原生所有者。

服务工作者由模块根句柄持有，不随页面 task 取消；AppLifecycle 的等待不会伪造不合作依赖已经结束。OS 下载回调与业务图分离，模型制品服务拥有真实传输及完成处理；设备安全不能使用后台额度作为保证。

[App](../README.md) · [装配](../Composition/README.md) · [测试](../../../Tests/AppWorkflowTests/README.md)

## 待实现

- 强制中断非合作服务、独立多窗口运行及进程被系统终止时的完成保证。

## ForegroundPreparation

✅ 同文件的 Foundation 独立准备协调器接收 readiness 步骤、prepare、允许准备条件及状态／失败回调；具体业务接线归 [Composition](../Composition/README.md)。

一个 worker 和一个待重检锁存位，无事件队列。代际围栏拒绝迟到结果；失活、配置替换或 stop 先关闭结果接纳，必须等旧 worker 实际退出后才能启动替代。stop 幂等加入并释放回调，不承诺系统原生加载立即停止。

步骤串行执行，全部完成后统一复查；后续步骤使先前能力不再就绪时明确失败，不循环重载。活跃交互只检查，终态请求刷新。内部 notReady 保留原始验证错误并调用 onValidationFailure；具体能力错误由能力拥有者报告。只在失败状态允许显式重试，无手动 cancel／cancelled 状态。

Step.prepare 接收实际加载事实回调：当前代际的 true 投影 preparing，false 立即投影 checking，prepare 返回后再复查。普通检查和进入 prepare 本身不表示发生加载。
