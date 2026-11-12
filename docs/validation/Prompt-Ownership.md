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

## 2026-11-11 cognition 提示词资源归属

### 最终范围

提示词资源只供 cognition Agent 使用。System 重命名 Shared，Assistant 输入协议归自身，Assistant/Writer 业务模板按职责拆分；完整固定分类/内容指令使用 Markdown。四个 perception 角色均无提示词文件。Actions 与 ModelKit 的源码、文档及 Package.swift 与本轮修改前一致；Resources/Actions、临时 ModelKit 提示词与两个加载器已撤回，Action 返回协议未改变。现有 Models 非提示词资产不变。

共享协议、目录模板与迁移前源字节一致；Writer Markdown 固定指令在请求组合后保持原文本。模板变量严格校验、用户内容单次插入、时间线来源防伪与角色归属回归通过。Xcode 资源分组与文件目录一致，没有加入本地下载模型文件引用。

### 验证结果

- `./scripts/check.sh` 退出 1。静态架构/资源边界、严格 Swift 格式、7 项 Python 测试及 plist 校验通过。1153 项集成测试仅 `slowTrackingDispatchExecutesOnlyTheNewestPendingTarget` 的第二个目标角度断言失败；该用例及 Photographer/NexArm 实现未在本轮修改。188 项 AppWorkflowTests 与 229 项 LiveRuntimeTests 通过。NativePresentationTests 有启动及部分单项记录，缺少套件结束证据，不能宣称整套通过。日志：`/tmp/mh-cognition-prompts-check.log`。
- 不改测试期望值，串行定向复跑上述 NexArm 用例、资源归属与字面变量、全部 Agent JSON 打包编译、Writer 格式与重试规则，4 项全部通过。此结果表明失败在本次串行运行未复现，不代替全量检查成功，也不确定其根因。日志：`/tmp/mh-cognition-prompts-focused.log`。
- `./scripts/build-ios.sh` 首轮主应用编译成功，字节校验检测到构建期间更新的 Skills/README.md 仍为旧副本。复跑后四个目标全部构建成功，最终应用包 52 项 Agent/Skill 资源逐字节校验通过；旧 System 目录及 Actions/ModelKit 提示词 bundle 均不存在，Island 校验通过。最终日志：`/tmp/mh-cognition-prompts-ios-final.log`。
- Writer 评估脚本的 Writer/Shared 完整资源预检通过；Python 语法、变更文档链接与 `git diff --check` 通过。预检只执行资源检查，没有读取凭据或调用供应商。

### 验收边界

本轮没有真实模型、完整原生 UI、安装或物理设备验收。自动测试使用替身与合成输入；编译和包校验不证明真实模型行为或设备效果。全量测试的 NexArm 失败与 NativePresentationTests 完成证据缺口仍保留，未用定向通过覆盖失败记录。

## 2026-11-11 cognition 提示词版本真机安装

按用户要求，使用现有本地签名配置构建 MobileHarness Debug `0.1.0 (2026111109)` 成功。严格深层签名、52 项 Agent/Skill 资源逐字节校验和 Live Activity 校验通过。覆盖安装到已配对 iPhone 17 Pro 成功，安装序号 6696；设备应用清单读回同一版本。没有卸载或清空应用数据，也未修改仓库签名配置。

自动启动失败：CoreDevice 10002，底层 FBSOpenApplicationErrorDomain 7 / Locked，系统明确表示手机未解锁。此次确认安装和版本，不宣称成功启动、原生交互或真实模型验收。日志 `/tmp/mh-cognition-device-{build,signature,install,launch}.log`，设备回执 `/tmp/mh-cognition-device-{before,install,launch,version}.json`。

该安装包含本轮 cognition 提示词资源迁移；网页截图仍走原有回执观察链路，统一视觉 State 尚未实现，方向记录在需求计划中。

## 2026-11-12 Assistant 同业务资源合并

- Assistant 的提示词文件从 8 个合并为 5 个。核对了迁移字段与原值，主请求输入规则保留原有首尾换行处理后的 809 字节，分类规则保留原有 268 字节及末尾换行。内容核对见 `/tmp/mh-assistant-prompt-merge-content.log`。
- `./scripts/check.sh` 退出码为 0。IntegrationTests 1,158 项、AppWorkflowTests 194 项、LiveRuntimeTests 229 项均通过，包含模板加载、输入分类、时间线排版、旧历史回放和任务摘要。NativePresentationTests 日志缺少整组结束记录。日志见 `/tmp/mh-assistant-prompt-merge-check.log`。
- `./scripts/build-ios.sh` 四个目标构建成功。最终包的 49 项 Agent 和 Skill 资源与源码逐字节一致，文件集合校验确认已合并的文件从包中移除，Live Activity 校验通过。日志见 `/tmp/mh-assistant-prompt-merge-ios.log`。

## 2026-11-12 Assistant 信号权限核对

- Assistant 入站删除三项无生产发送方的任务命令，定向任务权限从四个角色收窄为 Writer。生产声明的语音路由测试和跨 Gateway 语音占用测试通过，日志见 `/tmp/mh-assistant-communication-focused.log`。后续单向 ASR 方案另见 [语音完成文本契约](../requirements/technical/ASR-User-Input-Plan.md)。
- 四个 iOS 构建成功，最终包 49 项资源与源码一致，日志见 `/tmp/mh-assistant-communication-ios.log`。
- 完整检查退出码 1。IntegrationTests 的 `multiSourceActionResultStartsRequestBeforeOtherActionCompletes` 两个参数组合在并发运行时分类请求计数断言失败，随后串行复跑均通过。AppWorkflowTests 194 项与 LiveRuntimeTests 229 项通过，NativePresentationTests 日志缺少全组结束记录。完整检查和串行日志分别为 `/tmp/mh-assistant-communication-check.log` 和 `/tmp/mh-assistant-communication-serial.log`。
