# 资源跟随所属模块

## 目标

静态资源跟随使用它的 SwiftPM target，由 SwiftPM 生成 `Bundle.module` 读取，不再由 Agents 代为打包 Actions 的资源，也不再通过 `AgentConfigurations.actionResourceRoot()` 转手。`MobileHarness/Resources/` 只保留 App 自有资源。

## 目录调整

| 现在 | 之后 |
| --- | --- |
| `Resources/Actions/Localization/` | `Actions/Resources/Localization/` |
| `Resources/Actions/README.md` | `Actions/Resources/README.md` |
| `Resources/Agents/` | `Agents/Resources/Agents/`（包内路径仍是 `Agents/...`） |
| `Resources/Skills/` | `Agents/Resources/Skills/`（包内路径仍是 `Skills/...`） |
| `Resources/Catalog.json` | `Agents/Resources/Catalog.json` |
| `Resources/Assets.xcassets`、`PrivacyInfo.xcprivacy`、`README.md` | 不动（App 自有） |

包内相对路径保持不变，因此 `Catalog.json` 的索引、Agent/Skill 加载代码和 `Bundle.module` 查找逻辑不改。

## 代码与构建变更

- `Package.swift`
  - Actions target 增加 `resources: [.copy("Resources/Localization")]`，并排除 `Resources/README.md`。
  - Agents target 的 `path` 由 `MobileHarness` 收窄为 `MobileHarness/Agents`，`sources` 与 `exclude` 改为相对该目录；资源为 `.copy("Resources/Agents")`、`.copy("Resources/Skills")`、`.copy("Resources/Catalog.json")`。
- `ActionLocalization.translations(for:)` 直接使用 Actions 的 `Bundle.module`，删除 `resourceRoot` 参数；`AgentConfigurations.actionResourceRoot()` 删除；App 与测试夹具同步调整。
- pbxproj：文件引用路径与分组跟随新目录。
- `scripts/resources/verify-app-agent-resources.py`：Agent/Skill 资源在 `HarnessKit_Agents.bundle`，Action 翻译改为校验 `HarnessKit_Actions.bundle`。
- 边界检查与测试中写死的 `MobileHarness/Resources/...` 路径、`experiments/assistant/assistant-evaluation.json` 中的 Controls.md 路径随之更新。
- README：`Resources/README.md` 只描述 App 自有资源并指向各模块资源目录；Actions、Agents README 与 `Resources` 下原 README 的内容迁入对应模块；各处 `Resources/Agents|Skills|Actions` 链接同步。
- 历史文档与实验结果（`docs/validation`、`docs/completed`、`docs/history`、`experiments/*/results`）保持原样。

## 验收

`./scripts/check.sh` 与 `./scripts/build-ios.sh` 通过；打包校验确认两个 bundle 的资源与源文件字节一致且无多余文件；真机验收需另行进行。
