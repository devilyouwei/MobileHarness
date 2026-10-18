# External Device Connectivity

## Summary

Transport and protocol capabilities for external hardware; the current implementation is NexArm USB/BLE.

## Ownership and boundaries

No gesture catalog, presentation, Agent admission or recovery policy. NexArm owns bounded framing, native session fencing and connection facts; callers own what commands mean.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 Callers[ActionBindings] <--> NexArm[NexArm SDK]
 NexArm <--> Device[USB or BLE firmware]
```

## Structure and contract

[NexArm](NexArm/README.md) owns the link protocols, packet encoder/decoder, timestamped telemetry, USB serial and CoreBluetooth implementations. Connection/subscription success exposes a usable transport without pose probes or indication motion. Motion arrival is a caller-owned interpretation of feedback.

Discrete operations reject excess work explicitly. Live control returns whether a packet was actually admitted; the caller owns its latest intent. Disconnect invalidates old observation/control sessions, and no failed command is replayed.

NexArm transports and protocol values.

## Related design

[Parent design](../README.md) · [NexArm](NexArm/README.md)

## 待实现

- 暂无本目录独立的实现待办；跨模块及实际模型/设备验收见所属模块说明。

## Platform 根、设备接入与同帧呈现

✅ ConnectivityContainer 持有惰性驱动的 BLE 句柄，并在 macOS 提供最多一个显式打开的串口。构造/根 start/关闭未使用句柄均不初始化 CoreBluetooth。admission 关闭后拒绝新连接和写入；stop 关闭链路并检查断开确认，失败交回根。业务重连、运动语义和 UI 仍归 Actions 集成。

## 统一容器异常通道

✅ Connectivity 根及原生 BLE/串口失败经 PlatformAdmission 原生回调报告；连接状态/订阅原语不改变，正常断开不报故障。

✅ openSerial 返回 NexArmObservableLink，根唯一持有原生 serial 并管理真实关闭；BLE 通过 NexArmBluetoothLink 输出，连接、观察和安全约束独立保留。
