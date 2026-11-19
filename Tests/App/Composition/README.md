# App composition tests

| 文件 | 职责与执行 |
| --- | --- |
| [FoundationFailureTests.swift](FoundationFailureTests.swift) | 基础错误来源、分类和清理错误组合；默认 Swift 测试 |
| [RootCompositionTests.swift](RootCompositionTests.swift) | ApplicationContainer 根/子能力身份和作用域隔离，以及 UI 消费者/Actions/Gateway 的生命周期顺序与回滚；默认 Swift 测试 |
| [ProductionCompositionAcceptance.swift](ProductionCompositionAcceptance.swift) | 编译实际 ServiceFactories、ModuleRegistration、AppComposition；启动、UI 设置请求、导航、前后台、停止及停止后的拒绝 |

生产装配通过 `./scripts/simulator/test-composition.sh` 显式执行。APP_COMPOSITION_ACCEPTANCE 仅切换 Simulator 验收入口，普通 App 不执行测试。验收创建全新模拟器，以临时根存储和独立语言偏好装配真实服务；不下载权重或发起真实模型请求，不打开麦克风或相机。验收产物独立放在 build/CompositionAcceptanceDerivedData（MOBILEHARNESS_COMPOSITION_DERIVED_DATA 可覆盖），不会替换普通 Simulator App；结果保留在该目录的 composition-acceptance.json；进程超时、失败和清理分别由运行器报告。
