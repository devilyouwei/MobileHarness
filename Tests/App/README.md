# App tests

验证宿主生命周期、模块装配和应用接线；跨模块业务测试跟随发起工作流的所有者，Assistant/Writer/感知归 [Agents](../Agents/README.md)，通信调度归 [Gateway](../Gateway/README.md)。物理目录不改变既有 SwiftPM target。

| 目录 | 验证职责 |
| --- | --- |
| [Composition](Composition/README.md) | 根实例注册、基础错误、生产 App 装配的独立 Simulator 验收 |
| [Lifecycle](Lifecycle/README.md) | 启动图、回滚、前后台、环境通知及独立输出消费 |
| [Settings](Settings/README.md) | 保存/恢复、草稿、冲突、Provider 和角色配置 |
| [Resources](Resources/README.md) | 资源管理的 UI 接线、准入及变化通知 |
| [Presentation](Presentation/README.md) | 历史/窗口/提示/原生请求回执与生命周期协作 |
| [Speech](Speech/README.md) | 输入激活、权限/首帧、取消恢复及 UI/执行接线 |
| [Camera](Camera/README.md) | 相机/视觉重启与已提交照片的后续反馈 |
| [Web](Web/README.md) | 作品工作区、截图与请求上下文的集成 |

默认运行 `./scripts/check.sh`。生产装配另用 `./scripts/simulator/test-composition.sh`，创建并清理专用模拟器和临时数据；不加载真实模型、不使用开发者凭据。Writer 工作流回归归 [Agents/Writer](../Agents/Writer/README.md)，仍由原 AppWorkflowTests target 编译。

测试使用显式模型/设备替身验证业务流程；真实模型、原生 UI 与物理设备结果单独报告。覆盖和运行结果见 [模块审查](../../docs/validation/Module-Test-Coverage.md)及[修复验证](../../docs/validation/Module-Test-Repairs.md)。
