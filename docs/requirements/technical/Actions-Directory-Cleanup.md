# Actions 目录整理

## 目标

让 `MobileHarness/Actions` 的目录职责一致：模块根只放入口与模块级契约，具体能力跟随所属目录，装配文件集中，共享机制留在 `Support`。用户已批准新增下列目录。

## 规则

1. 域根只保留：`<Domain>Module.swift`、`<Domain>Actions.swift`（命名空间）、域级根服务/Endpoint、域级契约和 README。
2. 具体能力放 `<Domain>/<Capability>/`，同一能力的 Actions、Workflow、Service、Session、Adapter 同目录。
3. 跨域共享机制与中立端口留在 `Support`（Contracts/Function/Shell/Call），不新增目录。
4. 少于约 25 行且只服务单一邻居的文件合并进该邻居。

## 变更

| 范围 | 调整 |
| --- | --- |
| Actions 根 | 新增 `Composition/`：ActionsBusinessAssembly、ActionsBusinessBindings、ActionsUIFacades、BehaviorAssembly、BehaviorProtocolBindings、ActionEndpoints。根保留 ActionsContainer、ActionsFailure、CapabilityModules；ActionLocalization 是跨域机制，放入 `Support/Localization/`。 |
| Camera | 新增 `Capture/`、`Video/`、`Perception/`、`Album/`、`Preview/`、`Runtime/`；根保留 CameraModule、CameraCoordinator、CameraExecutionEndpoint。PhotoDispositionWorkflow 并入 CameraCaptureWorkflow。 |
| Artifacts | 新增 `Workspace/`、`Editing/`；根保留 Module、Actions、ArtifactService。 |
| History | 新增 `Conversation/`、`Presentation/`；根保留 Module、Actions、HistoryCapabilities。 |
| Web | 新增 `Page/`；根保留 Module、Actions。 |
| UI | RuntimePresentation 移入 `UI/Runtime/`。 |
| Speech | AudioDetectionTypes 并入 AudioDetectionCapabilities。 |
| 说明与翻译 | 40 个应用内部 Action 补真实英文 doc（修正 doc 与 title 相同、`UI.Island.end` 复用 present 文案）；新增测试：Skill 绑定的 Action 必须有 zh-Hans 翻译。 |

## 同步修改

`MobileHarness.xcodeproj` 文件路径、`Package.swift` exclude 中的 README、`scripts/checks/check-modelkit-boundaries.py` 的硬编码路径、受影响 README；`MobileHarness/Actions/README.md` 在完成后只描述已实现布局。

## 验证

`swift build`、`swift format lint --strict`、边界检查与 Python 单测、两阶段 `swift test`、`plutil -lint`；`build-ios.sh` 视 Xcode 可用性。
