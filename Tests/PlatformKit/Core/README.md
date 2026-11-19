# Core tests

## Passive native State regressions

PlatformStateTests covers deterministic local-time midnight/weekday/leap-day/DST/zone behavior, invalid dates, native observation replacement and unknown values, root admission/resume/stop, context JSON wrapping/re-read and malformed/oversized snapshots. BasicSkill's eight-source contract is asserted. Existing photography/ReACT acceptance inspects all eight sources in actual model requests and preserved request history. Shared and Qwen fixtures use explicitly synthetic FixedPlatformState rather than host device facts; model/device performance and native hardware acceptance are separate.

## 文件归属

- [PlatformContainerTests.swift](PlatformContainerTests.swift)
- [PlatformStateTests.swift](PlatformStateTests.swift)

ApplicationContainer 的根注册和 UI 生命周期组合测试归 [App/Composition](../../App/Composition/README.md)；本目录保留 Platform 根准入、失效、关闭、原生状态及观察契约。
