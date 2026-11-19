# Gateway tests

## Gateway container ownership

GatewayContainerTests covers inert construction, once-only configuration, failure propagation, cached-port fencing, terminal controls, scheduled/direct cancellation, joined native cleanup, root replacement using synthetic functions and resources. Observation-session coverage checks bounded diagnostic isolation and App-root cleanup. SoundSourceTests exercises the root-owned observation path with synthetic PCM, without real inference or device control.

## 文件归属

- [Input](Input/README.md)：所属子能力的测试与资源。
- [Output](Output/README.md)：所属子能力的测试与资源。

App 根注册身份、宿主顺序与回滚用例归 [RootCompositionTests](../App/Composition/RootCompositionTests.swift)；本目录只保留 Gateway 自身及其执行端口的契约。
