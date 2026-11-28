# Output tests

输入输出路由中本目录能力的测试。测试通过真实接口及显式替身验证可观察行为、失败、取消和清理；真实模型及设备用例保留显式 gate。

## 文件归属

- [GatewayContainerTests.swift](GatewayContainerTests.swift)
- [MediaTransportTests.swift](MediaTransportTests.swift)
- [NativeAttachmentTests.swift](NativeAttachmentTests.swift)
- [WindowGatewayTests.swift](WindowGatewayTests.swift)

Channel 调度、资源仲裁、直接调用和结果账本属于 Actions Shell，其测试位于 [Tests/Actions/Execution](../../Actions/Execution/README.md)；GatewayContainerTests 只验证 Signal 端点、准入、暂停/恢复围栏和执行端口转发。

GatewayContainerTests 的频道事件回归验证 scope/session/来源过滤、独立队列和取消；消费回调关闭自身订阅后仍可完成当前确认，后续事件不再接收。

频道级无 scope 监听的回归覆盖多个任务 scope、无 scope 事件及交叠绑定拒绝；它不增加 broker 持久性或迟订阅重放。

视觉会话回归通过真实 Gateway 和 Actions 执行端点验证请求链隔离。相机启动和 UI 呈现使用替身。原请求的同步重入触发循环保护，独立会话在原请求返回后依次收到骨架与视线 Tool 的实际执行回执。暂停会取消并加入等待下一帧的会话。
