# 提示词所有权验证

日期：2026-11-08。范围见[需求与实施方案](../requirements/technical/Prompt-Ownership-Plan.md)。

## 实施结果

各角色 Agent.json 升为 v8 并维护公开 description；Support 投影为不变的 AgentCore v7 函数/通信配置。Assistant 只维护自身身份，BasicSkill/TaskActions 维护通用 Task 教学，Writer 私有控制及内容格式指令迁入自身资源。实际请求通过当前实例权限与同一执行适配生成公开目录；只有受支持且获授权的 Writer 可被委派。

## 自动验证

- 定向回归：7 项测试通过，含 9 种无效元数据、8 种文件路径/格式、权限收窄、私有指令隔离、Writer 自描述、Task 平级教学与不可加载 writing。日志：`/tmp/mobileharness-prompt-focused.log`。
- 首次全量检查揭示两处测试仍引用旧 delegation 模板/旧章节名，已改为自描述与 DELEGATABLE AGENTS 契约；该次普通 IntegrationTests 为 1090 项、仅此 2 处失败；原生 LiveRuntimeTests 的 227 项全部通过（207.801 秒）。修正后 `./scripts/check.sh` 完整复验退出 0：架构/资源边界、6 项 Python 测试、Swift 严格格式、各包自动测试和 plist 校验全部通过；普通 IntegrationTests 的 1090 项全部通过（65.398 秒），原生 LiveRuntimeTests 的 227 项全部通过（206.402 秒）。日志：`/tmp/mobileharness-prompt-check-final.log`。
- `./scripts/build-ios.sh`：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四目标全部构建成功。最终 App 的 30 项资源逐字节校验通过，包含 Writer 新增 Instructions.md 和 Prompts.json；Core 协议与 Island 资源校验通过。日志：`/tmp/mobileharness-prompt-ios.log`。

- 文档新增引用路径及相对链接检查通过；`git diff --check` 通过。

## 验收边界

自动化使用合成输入和模型替身，证明装配、授权、格式及执行回归，不证明真实模型一定按提示词选择动作。尚未运行真实模型重测截图中的卡通化绘图、查找打开作品及并存前台目标，也未做物理手机验收或安装。本次不修改历史验证中的失败记录。

## 2026-11-11 Assistant System 输入与输出协议

- 静态边界、Swift 严格格式、7 项 Python 检查和 plist 校验通过。提示词章节、实际 Assistant 请求、时间线、动态目录与原生工具声明回归通过。188 项 AppWorkflowTests、229 项 LiveRuntimeTests 通过。NativePresentationTests 日志只有启动记录，缺少该套件的完成证据。
- `scripts/check.sh` 退出 1。集成阶段有两项前台任务测试失败。`fullDuplexTaskEndPersistsAndFoldsWhileGenerationAndAnotherChannelAreRunning` 在全量运行达到 60 秒限制，串行复跑通过。`assistantPhotographyForegroundTasksPersistThroughSQLite` 在全量运行报 `.expired`，串行复跑报 `agent.error: conflict`。同一拍照用例在迁移前已有失败记录。日志 `/tmp/mobileharness-system-protocol-check.log`、`/tmp/mobileharness-system-protocol-task-rerun.log`。参见 [迁移前验证](Provider-Management.md#2026-11-11-agent-brains-总页与独立配置)。
- 清理职责重叠后的 `scripts/build-ios.sh` 四个目标通过。最终应用包的 35 项 Agent／Skill 资源逐字节校验通过，覆盖两份 System 协议、Assistant 指令与 BasicSkill revision 53。旧 Core 协议清理和 Live Activity 校验通过。日志 `/tmp/mobileharness-system-protocol-final-ios.log`。
- 最终 `scripts/check.sh` 复验仍因上述两个集成用例超时退出 1，188 项 AppWorkflowTests、229 项 LiveRuntimeTests 与静态、格式、Python 和 plist 检查通过。最终串行定向 9 项通过，包含协议职责、授权目标与种类配对、模型实际请求、预算以及前台 `task.end`。日志 `/tmp/mobileharness-system-protocol-final-check.log`、`/tmp/mobileharness-system-protocol-final-focused.log`。模型测试使用替身。
- 分离 `ActionCatalog.json` 后，三个目录模板正文与迁移前逐字一致。6 项串行定向测试和 iOS 四个目标通过，最终应用包 36 项资源校验通过。全量检查仍有上述两个集成用例超时，229 项 LiveRuntimeTests 通过。日志 `/tmp/mobileharness-action-catalog-{focused,ios,check}.log`。

## 2026-11-11 多格式提示词加载

- `InputProtocol.md` 的正文与原 JSON 片段逐字相同，System 输出规则和 Action 目录的具名键分别校验通过。Markdown、TXT、JSON 渲染、变量校验、卸载重载和已取得模板的快照回归通过。Assistant 请求装配、目录预算、Writer 内容模板、Memory 标题模板通过。静态边界、Swift 严格格式、7 项 Python 检查、plist 及 `git diff --check` 通过。
- `./scripts/build-ios.sh` 首轮主应用构建完成，应用包检查发现资源 README 在构建期间更新后仍保留旧副本。复跑后四个目标构建成功，主应用包 36 项资源逐字节校验通过。日志 `/tmp/mobileharness-prompt-loader-ios-rerun.log`。
- `./scripts/check.sh` 退出 1。集成阶段共 1151 项，既有 `task.end` 跨 Channel 用例达到 60 秒限制，拍照任务 SQLite 用例报 `.expired`。188 项 AppWorkflowTests 与 229 项 LiveRuntimeTests 通过。NativePresentationTests 有部分单项结果，缺少套件结束记录。日志 `/tmp/mobileharness-prompt-loader-check.log`。真实模型与物理设备未纳入本轮验证。
- 串行定向复跑 10 项全部通过，包含 `task.end` 跨 Channel、三种资源格式、卸载重载、真实请求装配、目录预算、Memory 标题和 Writer 内容模板。日志 `/tmp/mobileharness-prompt-loader-focused.log`。

## 2026-11-11 固定输出协议

- `OutputProtocol.md` 不含 Channel 插值或具体 Channel 名。基础与 Photography 已加载两种请求使用同一份输出规则，Camera 只在 Photography 生效后的 Action 目录出现。协议、角色、委派、输入时间线和状态图片回归通过。
- `./scripts/build-ios.sh` 四个目标通过，最终 App 的 36 项资源逐字节校验通过。`./scripts/check.sh` 集成阶段 1151 项中有两个已有用例失败：`task.end` 跨 Channel 用例超时，拍照任务 SQLite 用例报 `agent.error: conflict` 且缺少预期的活动 Task。188 项 AppWorkflowTests、229 项 LiveRuntimeTests 和静态检查通过。NativePresentationTests 缺少套件结束记录。日志 `/tmp/mobileharness-output-protocol-{ios,check}.log`。

## 2026-11-11 Assistant system 章节模板资源化

- 首条 system 正文在模板迁移前后逐字节一致，共 23390 UTF-8 字节。实际请求的 Skill／Agent 目录和动态 Action、Writer 反馈与追问（20 个用例组合）、状态图片映射（6 个组合）回归通过。
- `./scripts/build-ios.sh` 四个目标通过，最终 App 的 39 项资源逐字节校验通过，包含三个新增 System 模板。日志 `/tmp/mobileharness-system-templates-ios.log`。
- `./scripts/check.sh` 退出 1。静态边界、Swift 格式、7 项 Python 测试、plist、188 项 AppWorkflowTests 和 229 项 LiveRuntimeTests 通过。集成阶段的 1151 项中，既有 `task.end` 跨 Channel 用例超时，拍照任务 SQLite 用例报 `.expired`。NativePresentationTests 缺少套件结束记录。日志 `/tmp/mobileharness-system-templates-check.log`。
- 串行定向复跑 6 项全部通过，覆盖协议与目录、委派权限、Writer 上下文、状态图片和 `task.end` 跨 Channel。日志 `/tmp/mobileharness-system-templates-focused.log`。
- iPhone 17 Pro 真机签名构建、深层严格签名、39 项 Agent／Skill 资源和 Live Activity 校验通过。覆盖安装后设备清单确认为 `0.1.0 (2026111108)`，安装序号 6688，系统返回启动成功。本次真机验证覆盖安装和启动。日志 `/tmp/mobileharness-device-prompt-2026111108-{build,install,app,launch}.log`。
