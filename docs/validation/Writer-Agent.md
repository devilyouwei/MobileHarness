# WriterAgent 验证记录

2026-11-03，分支 `codex/writer-agent`，基线 `ada643ae`。本记录区分替身模型测试、生产 WebKit 原生验证和真实模型/设备体验。[实施计划](../requirements/Writer-Agent-Plan.md)。

## 覆盖范围

- 独立 Writer 通过真实 AgentManager/InputGateway/OutputGateway 接收后台请求，调用确定性作品服务，分离原生工具控制与原始内容流，发布实际磁盘文件。模型和窗口呈现为测试替身。
- 逐字符内容、中文/emoji/组合字符、跨分片引号/标签/围栏；源码不进入后续控制工具参数；截断不提交；取消执行未取消的草稿清理；预算跨恢复共享。
- 范围修改保留未选文本、读取引用失效、文件删除、版本冲突、草稿不替换成功版本、独立项目及跨任务流拒绝。
- waitingUser / interactionID 后继续同一项目；独立 Writer Provider/模型保存、稳定 ID 和凭据不进入设置 JSON。
- Markdown 转义及危险链接不转换为可执行链接。

## 执行记录

- 第一轮修订后的 `scripts/check.sh` 通过，包括普通 IntegrationTests 984 项、AppWorkflowTests 146 项和单独的 LiveRuntimeTests 225 项，以及其他测试目标、边界、格式、Python 与 plist 检查。这一轮不包含最后补充的全部回归，不代替最终检查。
- `scripts/build-ios.sh` 第一轮四个目标均通过：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero。最后完整构建 `/tmp/writer-ios-final-2.log` 四目标通过；浏览域清理后又单独构建 MobileHarnessSimulator，通过（`/tmp/writer-ios-app-final.log`），Agent/Skill 资源和 Live Activity 验证亦通过。
- `scripts/test-webkit-simulator.sh` 通过。生产 WebPageContainer 完成本地 HTML/CSS/JS、定时动画、两次版本渲染、JPEG 截图及 example.com 远程浏览；新增双页面脚本启停隔离和独立关闭检查通过。已查看 local-2.jpg，中文标题、流程节点和更新状态清晰，无明显裁切。
- 原生证据目录：`/Users/devil/Library/Developer/CoreSimulator/Devices/9CC7DAF2-4A23-471B-8277-A673D8ECBE7D/data/Containers/Data/Application/EE36FC28-4C02-410E-834B-88596390CC48/Documents`。该绝对路径为本机运行证据，不是项目运行依赖。
- 开发期间曾出现测试夹具缺少新角色/工具注册、iOS 前后台调用位置错误、测试初始化 API 和嵌套 Testing 宏错误；均据实际检查修正。Provider 回归初次未先 load 即 save，被既有持久化契约拒绝，已修正测试顺序。保留这些失败，不将首次执行描述为通过。

## 独立验收边界

未运行真实云端 Writer 模型：当前测试环境没有完整的既有模型 URL/Key/Model 测试配置，未读取或输出其他凭据。模拟器原生测试使用固定页面，不能证明真实模型能正确完成 Transformer 架构图或连续创作。未完成真机安装与真实模型的端到端交互验收；不声称真实模型、手机后台限制或完整应用通知体验已验收。DOCX 不属于本期实现。

剩余人工验收：设置独立 Writer 模型，委托 Transformer 图和动画，局部修改已有作品，双窗口并行，最小化/关闭后继续，前后台中断恢复，追问补充、取消和原会话完成通知，最后再次验证远程浏览互不影响。

## 最终自动化复核

- `scripts/check.sh`：通过（`/tmp/writer-check-final-2.log`），普通 IntegrationTests 986 项、AppWorkflowTests 150 项、独立 LiveRuntimeTests 225 项，以及其余测试目标、格式/边界/Python/plist 检查。
- 随后窗口关闭并发保护和浏览域残留清理：Writer/Artifacts/Web 定向回归通过（`/tmp/writer-web-final-focused.log`）；最终应用 iOS 构建通过。
- 最后补充 Assistant 侧追问与完成通知回归：通过（`/tmp/writer-notice-3.log`），两次通知独立结束，不调用 Assistant 模型。前两次夹具错误地与通信桥同时消费输出流、且未安装语音接收替身；修正夹具后通过，未以忽略通知断言绕过。
- 文档链接和 `git diff --check` 通过；完整格式与边界复核通过。源码仍在工作区，未自动提交。

## 编辑能力与 Writer 控制渲染复核（2026-11-03）

- 完整 `scripts/check.sh` 通过（`/tmp/writer-opt-check.log`）：IntegrationTests 988 项、AppWorkflowTests 153 项、独立 LiveRuntimeTests 225 项，以及其他测试目标、格式/模块边界、Python/plist。硬件专用条件测试按原配置跳过，不代表真机硬件验收。
- `scripts/build-ios.sh` 四目标通过（`/tmp/writer-opt-ios.log`）。此后补充入口移动扩展名检查、相同流式快照去重和嵌套入口读取根支持；最终定向测试通过（`/tmp/writer-opt-focused-final.log`），包含真实 Artifacts 服务与脚本模型测试，呈现探针仍是替身。
- 原生 `scripts/test-webkit-simulator.sh` 通过（`/tmp/writer-opt-native.log`）：嵌套入口从显式受控作品根加载兄弟 CSS/JS，验证样式计算值与脚本输出；两个独立页面脚本启停/关闭隔离、动画、两次完整渲染和截图、远程浏览均通过。已查看 local-2.jpg，中文和流程节点清晰。
- 本轮原生证据目录：`/Users/devil/Library/Developer/CoreSimulator/Devices/9CC7DAF2-4A23-471B-8277-A673D8ECBE7D/data/Containers/Data/Application/A477839F-ABE4-42A4-86F1-38D90A1D3F1D/Documents`。这是固定页面的 WebKit 测试，不是模型创作质量或整个 Writer/UI 链路验收。
- 新增回归覆盖：普通编辑在节流时间之后仍不渲染；单次 opt-in 预览及最后刷新；跨文件上下文与追加用户要求进入内容模型；Unicode 行定位与独立文件引用；搜索分页；目录整体校验/移动、入口格式约束、差异与撤销；历史源文件恢复；运行错误阻止发布。
- 开发中首次直接 Swift 测试误用 Command Line Tools，缺少 Metal 编译器；改用完整 Xcode 后编译通过。旧“跨文件引用全部失效”断言按新契约调整；新增测试曾错误地比较包含读取状态的整个草稿、或直接匹配被 JSON 转义的路径，改为比较文件内容及解码后的路径后通过。
- 未运行真实云端 Writer 模型或真机安装。本轮未新增凭据、目录、第三方依赖，未提交工作区修改。

最终应用复核：嵌套入口读取根支持加入后，MobileHarnessSimulator 构建通过（`/tmp/writer-opt-ios-verified.log`）；本轮所有修改源码的严格格式检查、文档链接检查和 `git diff --check` 通过。


## Writer 历史与文件导出复核（2026-11-03）

- `scripts/check.sh` 通过（`/tmp/writer-records-check2.log`）：普通 IntegrationTests 989 项、AppWorkflowTests 154 项、独立 LiveRuntimeTests 225 项及其他测试目标、格式、模块边界、Python/plist。后续补充的截图所有权和完整委托历史断言另作定向复核。
- 最终定向回归通过（`/tmp/writer-records-verified.log`）：真实 SQLite 关闭重开、Assistant/Writer 角色隔离、实际请求参数/源码/工具结果/取消状态；截图媒体引用可由 Writer 对应输入读取，Assistant 读取被拒绝；两种完整委托流程（直接完成/追问后完成）均保留历史并通过 Gateway 新建会话；ZIP 由独立解压器验证目录、UTF-8 内容和 CRC。
- `scripts/build-ios.sh` 四目标通过（`/tmp/writer-records-ios-final.log`）；媒体历史绑定加入后的应用构建通过（`/tmp/writer-records-ios-app.log`）。
- `scripts/test-webkit-simulator.sh` 通过（`/tmp/writer-pdf-native.log`）：嵌套 HTML/CSS/JS 原生 PDF、中文可选文本、140 段文档生成 6 页 A4 且末段完整。已查看首页和末页，未见文本裁切。证据位于本机模拟器 Documents：`/Users/devil/Library/Developer/CoreSimulator/Devices/9CC7DAF2-4A23-471B-8277-A673D8ECBE7D/data/Containers/Data/Application/36D3E210-8C42-458D-B631-2B7716824642/Documents`。
- 开发中曾因 FinishReason 非 RawRepresentable、测试缺少 await/try、Xcode 文件引用遗漏及历史 UI 直接修改仓库被检查拒绝；均已修正。补充完整委托测试首次将 Writer 注册限制在单个委托会话，导致独立历史 UI 会话返回 scopeClosed；按生产长期角色的无单会话限制注册修正后通过，未放宽 Gateway 校验。
- 原生 PDF 使用固定内容；模型测试采用替身。未验收真实云端模型、真机安装或设置页系统分享的手动交互。当前仅支持 HTML/Markdown/TXT 转 PDF；不声称支持 DOC/DOCX。历史保存使用共享 SQLite，图片由既有媒体存储保存，作品文件与临时导出位于 StorageFiles 工作区。

最终复核：设置页文件详情中的导出进度/错误展示补齐后，`scripts/build-ios.sh` 四个目标全部通过（`/tmp/writer-records-build-verified.log`）；全源码严格格式、模块边界、相关文档链接与 `git diff --check` 通过。工作区未提交。

## 当前版本真机安装（2026-11-03）

使用现有本地签名配置，MobileHarness Debug 真机构建通过（`/tmp/writer-device-install-build.log`）；30 项 Agent/Skill 资源与 Live Activity 打包检查通过。当前工作区已覆盖安装到已配对的 iPhone 17 Pro，bundle ID `dev.mobileharness.app`，安装数据库序号 5708（`/tmp/writer-device-install.log`），未卸载或清除应用数据。自动启动被系统以设备锁定拒绝（CoreDeviceError 10002 / Locked，`/tmp/writer-device-launch.log`）；安装成功不代表启动或 Writer 真机交互验收通过，待用户解锁后打开验证。


## 单任务委托与主动消息改造（2026-11-03）

本节替代此前“固定通知不调用 Assistant 模型”的当前实现结论，旧记录仅作为历史证据。

- 默认 native delegateTask 直接建立 Writer 后台 Task，sendMessage 定向回复或取消；Writer 单任务占用，Assistant 前台 Task 不切换。事件通过现有 Gateway 通信回执确认，终态采用先接纳业务证据、再确认 transport result 的两阶段发送。
- 新回归使用真实 Gateway/Task Actions/SQLite 与脚本模型，覆盖默认委托、原始输入和 goal、保留前台 Task、追问/过期 interactionID、竞争拒绝、取消、暂停重投、相同 eventID 重送、32 项队列压力、FIFO、历史关闭重开、窗口先于模型、恢复不重开窗口、紫色 Writer 详情与语音并存。这些并非真实云端模型或真机语音验收。
- 开发中发现历史 read-token 与并发输入接纳发生冲突，已将 read/begin 短事务纳入同一 admission gate；定向 FIFO/SQLite 回归通过。提示词预算曾超出既有限制，压缩新增说明，保留原有容量阈值。旧多任务、固定播报、缺少默认 Writer state 的测试预期均按新契约更新；没有放宽身份校验。
- 原生 WebKit/PDF 模拟器验收通过（/tmp/writer-delegate-native.log）：嵌套 HTML/CSS/JS、独立页面、远程浏览、截图、六页 PDF。固定页面证据目录为模拟器 9CC7DAF2-4A23-471B-8277-A673D8ECBE7D 下 Application/25209284-0F8E-4863-A85E-8D669196539F/Documents；不代表真实 Writer 创作链路已人工验收。
- 当前环境没有启用真实模型验收参数；真实模型、ASR/VAD 与 Writer 同时运行及系统分享等人工交互仍待验收。SQLite 保存来源/处理/模型与 Task 证据；运行时输入队列不宣称在重启后自动继续创作。

当前源码签名真机构建通过（/tmp/writer-delegate-device-final-current.log），Agent/Skill 30 项资源和 Live Activity 检查通过。已覆盖安装至 iPhone 17 Pro（dev.mobileharness.app，安装序号 5716，/tmp/writer-delegate-device-install.log），未卸载或清除应用数据。安装不代表真实模型/语音验收。

- 最终 scripts/build-ios.sh 四个目标全部通过（/tmp/writer-delegate-ios-accepted.log）；真机自动启动成功（/tmp/writer-delegate-device-launch.log）。
- 最终普通阶段 991 项 IntegrationTests 中仅 residentNativeStateSeedsOnceAndReadsNeverSampleSources 超时（原生状态等待上限三秒，实际并发阶段超过八秒）；其余包含 Writer/FIFO/SQLite 的测试通过。154 项 AppWorkflowTests 通过。提示词保持原阈值，通过值 base=25949、photography=37589 UTF-8 字节。该全量运行保留失败状态，单测复验另记，不将失败抹除。
- 文档相对链接检查、git diff --check、模块边界、严格 Swift 格式及 Python/plist 检查通过。工作区未提交。

最终运行时阶段：225 项 LiveRuntimeTests 全部通过（206.585 秒，/tmp/writer-delegate-check-accepted.log），plist 检查通过。完整 check.sh 因前述单项超时返回失败；该原生状态测试保持代码和断言不变，构建结束后单独复测通过（0.008 秒，/tmp/writer-native-state-recheck.log）。不将单独复测等同于全量一次通过。

## Assistant XML 与调度边界修正（2026-11-03）

本节替代上一节“默认原生 delegateTask”的实现结论。Assistant 当前基础与可加载 Skills 全部为 XML Function Token Action；delegateTask/sendMessage 与 startTask 一同归 BasicSkill，Writing 的 Artifact_library 也是 Action。生产 Actions 装配分别投影 scheduled Action 与 direct Tool；Writer 原生工具工作流不变，未修改 Gateway 调度机制。

定向验证使用脚本模型输出 XML delegateTask，经真实 ChannelScheduler 接纳 Writer；默认/已有前台任务两种情况下 FIFO、去重、SQLite 重开均通过。生产目录检查覆盖 Action scheduled/Tool direct，所有 Assistant Skill 无 tools，身份提示包含 Writer 及其他运行时角色职责并限定可委托目标。

开发检查曾失败于跨编译目标的内部初始化器及测试枚举比较，均修正为现有模块内适配和模式匹配。新增角色/示例使提示词超预算，压缩重复教学，保留原阈值；旧文本快照断言按等价教学更新，并保留拍照清理、独立语音、替换确认等行为约束。实际模型任务、真机语音交互未在本轮验收；本轮不自动安装或提交。

最终提示词/协议定向复测通过（/tmp/writer-xml-final-focus.log）：29 项集成用例及相关目标；默认提示词 25912 字节、photography 37552 字节，原容量限制不变。scripts/build-ios.sh 四目标通过（/tmp/writer-xml-ios.log）。后续补充 Writer 控制提示中的反向角色可见性与对应断言，独立复测与增量构建另记。文档本地链接与 git diff --check 通过。

最终完整 scripts/check.sh 通过（/tmp/writer-xml-check-final.log）：992 项 IntegrationTests、154 项 AppWorkflowTests、225 项 LiveRuntimeTests，以及其他目标、边界、格式、Python/plist。双向角色提示补充后的定向验证通过（/tmp/writer-role-final.log）：Assistant 可见职责/权限范围、Writer 控制模型实际收到 Assistant 角色说明、完成/追问/取消三条直接 Tool 工作流。最终 scripts/build-ios.sh 四目标再次通过（/tmp/writer-xml-ios-final.log），Agent/Skill 与 Live Activity 打包检查通过。真实云端模型、真机语音验收未执行；工作区未提交。

## Delegation timeout cleanup (2026-11-03)

Read-only inspection of the connected iPhone SQLite copy found task_135 delegateTask observation: handlerFailed / Action execution timed out; task status: failed / CancellationError. No generating messages remained at inspection time. No device database mutation was performed.

The production round reader stopped at roundFinished and joined an Action that emitted communication after that boundary, causing a receipt wait cycle. The previous test communication bridge bypassed this reader. Communication now drains independently across rounds through the same Gateway. Registration failure cleanup attempts both memory and persistence and aggregates errors. Writer terminal island content explicitly labels failure/completion/cancellation.

Tests now consume original Assistant outputs with real Gateway and stub model/Writer endpoints. Six cases cover foreground task present/absent and rejection/failure/completion, followed by history archival. Rejection also tests a subsequent delegation. The first expanded test run omitted the required cancelTask reason in test cleanup; fixing the test parameter passed all six cases without weakening production validation. Full check/build results follow. Revised native UI and real-model/device interaction remain unverified.

Final verification: scripts/check.sh passed (exit 0; /tmp/writer-cleanup-check.log), including all six delegation cases and 225 LiveRuntime tests. scripts/build-ios.sh passed all four targets (exit 0; /tmp/writer-cleanup-build.log). git diff --check passed. The diagnostic SQLite copy was removed from /tmp after inspection. No revised device installation or native UI/real-model acceptance is claimed.

## Task-oriented Writer records (2026-11-03)

The shared SQLite backend now stores stable delegated task/dialog/project bindings and separate execution Task rows. Migration v4 groups legacy Writer evidence by exact recorded taskID without changing message/media identities; unmapped/unauthorized directory associations remain read-only. Migration v5 adds workspace readiness: reserve and bind a project ID before starting the workspace, allow initialization retry only for that reserved not-ready project, and mark ready after successful window preparation. Existing ready projects are never silently recreated.

Writer records open as a task list, with run-separated native request/tool evidence, captured images, task JSON sharing and bound file snapshots. The former manual Writer conversation/title Action pipeline, shared Writer history UI state and separate global artifacts menu have been removed. File previews use the existing WebPageContainer (including local-root/network policy); HTML/MD/SVG render, other code is escaped, and source/ZIP/PDF exports use retained snapshots.

Automated coverage uses real SQLite, real Gateway/direct Tool execution and scheduled Assistant XML Actions, with explicitly synthetic models and Writer endpoints where applicable. Twelve Assistant cases cover foreground task preservation, rejection, completion/failure, resumption, forced replacement, cleanup rejection, late old-run messages and history archival. Six Writer execution cases cover normal streaming, ask/resume, Assistant cancellation, provider cancellation as failure, root stop as interrupted, and initial window failure followed by reuse of the same physical project directory. Storage tests verify resuming across another task, native call/result restoration, source Assistant deletion, stale run binding rejection and exact legacy evidence migration.

Initial validation caught a forbidden direct WebKit import in Settings (replaced with the existing Web component), an incomplete old media-only database fixture (updated to include the original core schema), and Assistant prompt budget growth (deduplicated without raising limits). One full run hit the existing native notification test deadline; its isolated rerun passed in 0.007s and the subsequent full integration run passed. Final Assistant prompt sizes are 25,987 UTF-8 bytes base and 37,627 with Photography, within existing limits.

Final focused run: /tmp/writer-task-reserved-project.log passed, including all twelve Assistant and six Writer cases. Final scripts/build-ios.sh: exit 0, all four targets succeeded (/tmp/writer-task-ios-accepted.log). Final scripts/check.sh integration phase passed 994 IntegrationTests and 155 AppWorkflowTests (/tmp/writer-task-final-check.log); runtime-phase completion is recorded below. git diff --check passed.

No real-provider inference, revised physical-device installation or native page interaction acceptance is claimed. The native automation app lookup for /Applications/Xcode.app/Contents/Developer/Applications/Simulator.app returned Invalid app. Simulator build success is distinct from interactive UI acceptance. No device database or user files were modified by this change's validation.

Workspace initialization follow-up: reserved project binding and workspaceReady are persisted before/after window preparation respectively. The final real Gateway Writer fixture now includes a first-window failure and explicit resumption: the project ID and the single physical UUID directory remain unchanged, and the task transitions from failed/not-ready to completed/ready. The focused reserved-project run passed all six Writer cases and twelve Assistant cases, plus native-history/legacy storage checks (/tmp/writer-task-reserved-project.log).

Final complete verification after this follow-up: scripts/check.sh exited 0 (/tmp/writer-task-final-check.log), including 994 IntegrationTests, 155 AppWorkflowTests and all 225 LiveRuntimeTests, plus remaining package, boundary, formatting, Python and plist checks. scripts/build-ios.sh exited 0 with all four targets successful (/tmp/writer-task-ios-accepted.log). git diff --check passed. Physical-device, real-model and native interactive acceptance remain unexecuted as described above; no installation is claimed.

## Physical-device installation (2026-11-04)

At the user's explicit request, the current MobileHarness Debug device build succeeded using existing signing configuration (/tmp/writer-task-device-build.log). All 30 Agent/Skill assets, Live Activity resources and strict/deep code signature checks passed. Installed over the existing app on Youwei’s iPhone 17 Pro (dev.mobileharness.app, installation sequence 5732; /tmp/writer-task-device-install.log), without uninstalling or clearing application data. devicectl launch succeeded (/tmp/writer-task-device-launch.log); a subsequent process query confirmed MobileHarness running as PID 18490. Installation and process presence do not establish native interaction, completed history migration, real-model inference or end-to-end Writer acceptance.

## Provider-default output budgets (2026-11-04)

Removed application-chosen maximumOutputTokens from Writer control (2048), Writer content (16384), conversation-title (64) and debug chat-diagnostic (32) requests. Assistant already used nil. OpenAI request encoding no longer rejects explicit budgets above 32768; absent budgets stay absent, so the provider applies its model default. This changes model token budgeting, not artifact/storage capacity contracts.

Regression evidence: Writer control/content requests all retain nil maximumOutputTokens; provider JSON contains no max_output_tokens/max_tokens/max_completion_tokens by default; an explicit positive 131072 budget passes encoding without a fabricated model-independent ceiling. Title-request regression now asserts nil. Focused checks passed (/tmp/model-output-default-focused.log). Full check results follow below.

Four simulator build targets passed (/tmp/model-output-default-ios.log). Signed device build passed (/tmp/model-output-default-device-build.log); 30 packaged Agent/Skill assets, Live Activity and strict/deep signature verification passed. Covered installation on iPhone 17 Pro succeeded, installation sequence 5740 (/tmp/model-output-default-install.log), and devicectl launch succeeded (/tmp/model-output-default-launch.log). Existing application data was retained. These checks do not claim real-provider inference or native interaction acceptance.

Final scripts/check.sh exited 0 (/tmp/model-output-default-check.log), including the title/default-budget regressions and runtime suite; the physical USB diagnostic remains explicitly skipped. scripts/build-ios.sh passed all four targets. git diff --check passed. No API key, provider configuration, or user conversation was altered by validation.


## Development storage reset and compatibility removal (2026-11-04)

At the user's request, old development history is discarded for every Agent. SQLite now owns one current schema marker (20261104), directly creates current domain tables/indexes, and erases all tables through GRDB before creating that schema when the marker differs. Current-format reopen does not erase data. Removed migration registration, legacy Writer grouping/read-only presentation and the legacy task flag. Existing recovery, transactions, ownership isolation and run identity checks remain.

Audited persistence beyond Writer: removed legacy Provider Keychain import/single-provider restoration and missing name/ID defaults, old speech preference switches, staging-prefix installation receipt repair, old downloader .hub-snapshot import, Artifact entry/index field defaults and old Island/ActivityKit snapshot conversion. Agent assets accept v7 only with explicit Skill instruction paths; task envelopes require execution scope. Required persisted fields no longer default to another format. Optional cache metrics, current nullable values, current-plan download resume and hardware/provider protocols are not retired storage formats and remain supported.

Regression coverage rejects retired JSON/configuration/signal shapes and checks current round-trips. The old SQLite fixture seeds Assistant and Writer histories, delegated task/run records, media and a selected device; reopening clears all of them. Existing current SQLite reopen tests retain chat/native tool evidence, media and task associations. Earlier check runs exposed tests still expecting old format defaults; those fixtures/assertions were updated rather than restoring compatibility.

scripts/build-ios.sh passed all four targets (/tmp/storage-no-compat-final-ios.log). Signed device build, 30 packaged Agent/Skill assets, Live Activity resources and strict/deep signature checks passed (/tmp/storage-no-compat-device-build.log). The app was installed over the existing iPhone 17 Pro app, installation sequence 5748 (/tmp/storage-no-compat-device-install.log). The ordinary launch command succeeded, but a subsequent terminate/relaunch needed to verify a fresh process was denied by iOS Locked (FBSOpenApplicationErrorDomain 7); device reset is therefore not claimed. Diagnostic copies still showed the pre-reset marker 0. Unlock and a fresh launch remain necessary for physical-device reset verification; no real-model or native interaction acceptance is claimed.

Simulator installation and fresh process launch succeeded (iPhone 18 Pro). SQLite changed from marker 0 to 20261104: messages/tasks/delegated_tasks/delegated_runs/media_files/devices were all 0, with one newly created empty current dialog. grdb_migrations is absent and PRAGMA integrity_check returned ok. This establishes simulator initialization and database reset, not full UI or real-model acceptance.

Final automation: scripts/check.sh exited 0 (/tmp/storage-no-compat-complete-check.log), including 995 IntegrationTests, 155 AppWorkflowTests and all 225 LiveRuntimeTests. The additional Artifact current-field/retired-shape regression passed separately after the full run (/tmp/storage-current-artifact-test.log); strict formatting lint passed for that addition. scripts/build-ios.sh exited 0 with four successful targets. git diff --check passed. A second simulator process launch retained marker 20261104 and its empty current dialog without generating history. Task-owned device SQLite/configuration copies were deleted from /tmp after metadata-only inspection. No conversation bodies, credentials, model weights or user media were added to the repository.

Final device retry could not establish the CoreDevice connection (4000, peer no longer reachable; /tmp/storage-no-compat-device-final-launch.log). Device reset remains unverified after the earlier explicit lock rejection. Reconnect/unlock and a fresh application launch are required before inspecting the current SQLite marker/counts.


## Workspace capacity and retry loop (2026-11-04)

The device's SQLite evidence showed task_138, task_139 and task_140 failed with capacity before workspaceReady and without Writer model requests. The Assistant produced repeated same-goal delegateTask actions after those failures. In that startup path, the old Artifact checkpoint rejected a ninth retained project identity (published projects, drafts and pending deletions), while the short title and empty draft were valid. This was an application quota, not a provider quota or a report of insufficient device RAM. The artifact index itself could not be copied because file protection denied access; the startup code path and SQLite failure/initialization evidence establish the cause.

Removed the project/version/file-count and source-byte quotas from Artifacts, and the residual 64KiB source-stream check in Writer. Current Storage document/filesystem capacity and I/O errors, path checks, paging and concurrent-window/queue bounds remain. Version reads use the actual confined file size; preview and exports do not impose a smaller source limit. Standard ZIP export preflights its field widths and reports ZIP64 requirements instead of trapping/truncating; this does not constrain generation.

The Assistant host now rejects delegateTask from Writer facts and from a second actual delegation attempt in the same user input. This removes the former fallback that substituted the model goal for the original user input when a Writer event caused a new delegation. Busy/parameter correction before any actual delegation remains possible, as do explicit retries/resumptions from fresh user input. Writer normalizes failed tool arguments, never executes an unchanged failed call twice without a successful draft change, and still permits repair/edit/render. Artifact range/reference/context/savepoint/title/query errors now name their constraint rather than reporting generic capacity.

Focused automated checks passed (/tmp/writer-capacity-focused.log): 10 independent projects and 18 retained revisions, large multi-file publish/restore, source streams exceeding 64KiB with nil model output budgets, repeated failed-effect suppression and edit-then-render recovery. The final Assistant fixture passed 16 real Gateway/Scheduler/SQLite cases (/tmp/writer-capacity-final-focused.log), including rejected-delegation retries, failed-event redelegation rejection, and fresh user retries; models and Writer endpoints in these fixtures are explicitly synthetic. Final prompt sizes are 25,981 and 37,621 bytes, within unchanged prompt checks. An earlier full run exceeded the base prompt check by 11 bytes; instruction wording was deduplicated without increasing its threshold.

Signed build, packaged resources/signature verification and an interim physical-device installation succeeded (sequence5756). Fresh launch was rejected by iOS Locked (FBSOpenApplicationErrorDomain7; /tmp/writer-capacity-device-launch.log). No real-provider, native interaction or physical end-to-end acceptance is claimed. Final builds/checks after the ZIP preflight follow below.

Final complete scripts/check.sh run exited 0 (/tmp/writer-capacity-final-check.log): 995 IntegrationTests, 160 AppWorkflowTests and all 225 LiveRuntimeTests, plus boundary/Python/format/plist checks. After that run, focused checks also passed for the final source-output/ZIP preflight follow-up (/tmp/writer-capacity-accepted-focused.log): control text above 4KiB and source above 64KiB remain intact with nil output budgets; unchanged failure suppression, corrected-draft recovery and standard ZIP format checks passed. Source changes after the complete run are covered by those focused checks; that complete run is not claimed to include the final follow-up test additions. Strict formatting and diff checks passed.

Final signed device build passed (/tmp/writer-capacity-accepted-device-build.log); the WriterWorkflow object was compiled after the last output-limit edit. Packaged Agent/Skill/Live Activity and strict/deep signature verification passed. Final covering install on iPhone 17 Pro succeeded, installation sequence5764 (/tmp/writer-capacity-accepted-install.log). Task-owned device database/index copies were deleted from /tmp. Fresh launch/native interaction remains separately recorded below.

Final iOS validation: scripts/build-ios.sh exited 0 with four targets successful (/tmp/writer-capacity-accepted-ios.log). A final incremental MobileHarnessSimulator app build also passed after the last control-text limit removal (/tmp/writer-capacity-final-app-build.log). The final signed build includes that edit, resource/signature checks passed, and sequence5764 is installed. Final device launch again returned Locked (/tmp/writer-capacity-accepted-launch.log), so real inference/native interaction remain unverified; unlocking and opening the app is still required. git diff --check passed.

## Requested device reinstall (2026-11-04)

Verified the current signed app has no newer application Swift/configuration/instruction source files, and packaged Agent/Skill, Live Activity and strict/deep signature verification passed. Covered installation on Youwei’s iPhone 17 Pro succeeded (sequence5812; /tmp/writer-reinstall-device.log). Fresh launch with terminate-existing succeeded (/tmp/writer-reinstall-launch.log); subsequent process inspection confirmed PID19084 running from the new installation. This supersedes the earlier lock-related launch blockage, but does not establish real-model drawing or voice interaction acceptance.


## Device first-test transport failure and classified diagnostics (2026-11-04)

Read the connected iPhone SQLite base/WAL without clearing data. PRAGMA user_version=20261104 and integrity_check=ok. The first/current Writer task_1 used qwen3.8-max and had workspaceReady=1. Request message_6 completed a native workspace list (empty result); message_8 was the second control request, failed with zero text/tool output and only code=transport/stage=http. Its timestamp to Task completion was60.03s; total Task duration64.45s. HTML content generation had not started. The raw URL error, received HTTP status and response body were not saved by that version, so the exact old network cause cannot be recovered. A transport failure is not evidence of any specific HTTP status.

The previous ChatNetworkSession assigned configuration.timeoutIntervalForResource=60. Apple's [resource timeout documentation](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforresource) defines a complete-transfer deadline; [request timeout](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforrequest) measures waiting for additional data and resets as data arrives. The device timing is strongly consistent with a timeout; losing URLError prevents distinguishing that overall deadline from a stalled connection in the old record. The adapter now applies timeout to idle request waiting and preserves the platform/caller resource setting. Cancellation and Agent task budgets remain; no retry/model switch was added.

ChatHTTPFailure now preserves safe numeric URL errors with timeout/DNS/TLS/offline/connection/cancellation/other classification and distinguishes pre-header HTTP from streaming. HTTP failures preserve status, validated request ID, structured code/type/param and a bounded credential/bearer/URL-redacted message; raw error bodies and NSError userInfo are excluded. Writer failures retain model, request inputID, phase, elapsed time, original cause and cleanup cause. Writer-owned wire diagnostics are explicitly projected into neutral Storage evidence and UI DTOs; no schema migration/new database or Support-to-Storage import was added. Earlier local checks caught the forbidden communication import and missing Xcode navigation references; ownership/projection and project references were corrected without relaxing boundary checks.

Focused tests passed (/tmp/writer-http-accepted-focused.log):5 provider tests (including6 URL-code cases) plus3 Writer integration tests with7 Gateway lifecycle cases. A1-second idle/1.6-second heartbeat fixture verifies an active stream may outlive the idle duration; no real provider was contacted. Gateway modelTransport output and Writer failed-event evidence are asserted, along with SQLite reopen/UI projection and primary-versus-cleanup causes. The initial HTTP fixture assertion expected the former status-only enum; it now verifies typed HTTP fields and discarded raw body instead. A test's nested #require and fixture concurrency capture were corrected before the passing run. Full checks/builds follow below.

Complete scripts/check.sh exited0 (/tmp/writer-http-check.log), including996 IntegrationTests,161 AppWorkflowTests,225 LiveRuntimeTests and all remaining boundary/format/Python/plist checks. scripts/build-ios.sh exited0 with four successful targets (/tmp/writer-http-ios.log). Subsequent focused checks cover the final provider-rejection category, primary-budget versus cancelled-child distinction, full task failure preservation, and18 Assistant Gateway/FIFO cases including UTF-8-safe4KiB failure projection (/tmp/writer-http-final-focused.log). Full failure events remain durable; truncating model observation text is explicitly marked and does not discard a queued event. Final incremental app builds follow this small follow-up. No real-provider retry was performed.

Final incremental simulator app and signed device builds succeeded after the final diagnostic/observation follow-ups (/tmp/writer-http-final-app-build.log, /tmp/writer-http-final-device-build.log). Packaged30 Agent/Skill assets, Live Activity and strict/deep signature checks passed. Covered installation on iPhone17 Pro succeeded (sequence5820; /tmp/writer-http-install.log); fresh launch succeeded (/tmp/writer-http-launch.log), and process inspection confirmed PID19128. Post-install SQLite retained marker20261104, integrity_check=ok, failed task_1 with its original transport/http evidence; four Writer response rows were present in the post-install snapshot. No database reset was performed. Device copies were removed from /tmp after metadata-only inspection. Installation/startup and local fixtures do not establish a successful real Qwen retry.


## Writer autonomous execution and report playback handoff (2026-11-04)

Writer owns file operations, raw generation, explicit/stream preview, model looping, ask/finish, cancellation and cleanup. Removed WriterBudget and the 24-control/24-content/600-second task deadlines; provider output defaults and existing context/tool/queue confinement remain. A 31-request scripted regression finishes normally after the former limit and retains its goal after context trimming. Writer progress transport now has a separate owned worker: per run at most one unsent event per kind plus its immutable in-flight event, with same-kind pending progress replacement and unchanged event IDs on retry. Reporting rejection/unavailability does not abort, rerun or delay creative model/file execution. Terminal creative status is persisted after cleanup, before delivery; transport confirmation retains the existing single-task replacement boundary. Storage/final-report preparation failures produce a failed fallback report instead of leaving a busy slot with no terminal event.

Assistant close/interrupt preserves Writer work and queued Writer facts. Reports retain trusted task/source-dialog provenance but enter the current conversation without reading old private context. All report kinds share final-text FIFO admission, deduplication and capacity rejection. Writer inputs wait for the current round/actual playback and foreground peer reply completion; releasing peer occupancy resumes drain. Successful Writer report decisions publish the last completed report ID and its monotonic start time with ReplyActivity snapshots. SpeechPerception alone enables listening from that fact. Off-state occupancy does not schedule a cancel-reply Action; explicit stop, capture termination, pause and root shutdown fence older completions. Completion facts are retained in later snapshots so reordered communication consumption cannot lose the successful boundary.

Focused `/tmp/writer-autonomy-final-focused.log` passed: 30 Assistant real Gateway/Scheduler/SQLite cases, eight Writer Gateway/direct-artifact lifecycle cases (including a fully blocked report receiver while creation/publish complete), six listening-policy variants and source/duplicate/stop tests; presentation, model, speech and the added peer-occupancy fixture are explicitly controlled substitutes. The playback fixture holds the registered Speech.Playback.speak Action until released, asserting no Writer inference or successful report fact before the drain boundary. The subsequent peer-occupancy additions and final fallback/Instruction edits are included in the final full run below, not retroactively attributed to this focused log.

The first full run failed on the existing prompt-size threshold and stale off-state Action-count expectations; an old test indexed its expected missing Action and trapped. Updated those assertions to the intended no-cancel behavior and compacted duplicate instructions without increasing prompt limits. Four simulator build targets passed that first build; final code/packaged-instruction validation is recorded separately below. No real-provider, physical microphone or iOS interaction acceptance follows from these substitutes.


The next full run exposed two exact-phrase Instruction assertions and a fixture completion-count ambiguity: independently consumed ReplyActivity envelopes have their own agent.finished. Restored the contract wording within the unchanged prompt limit and made the fixture identify decisions by actual roundFinished boundaries. That stricter probe then confirmed a production queueFull: publishing a same-busy snapshot for each of 32 queued inputs overflowed the 16-item communication consumer and left an actual reply waiting. The publisher now sends complete snapshots on occupancy/session transitions, new final-speech root acknowledgements and successful report boundaries; ordinary same-busy text/Writer input changes coalesce locally. No input/SQLite/FIFO item is dropped, no queue capacity or playback barrier was relaxed. `/tmp/writer-autonomy-coalesced.log` passes the 32 Assistant cases and report/consent checks after this fix. Final checks below include it.


Final complete `scripts/check.sh` exited0 (`/tmp/writer-autonomy-final-check.log`):1001 IntegrationTests,161 AppWorkflowTests,225 LiveRuntimeTests, the remaining suites, boundary checks, six Python checks, strict Swift format and plist checks passed. Explicit opt-in real-model evaluation remains skipped. Prompt sizes are25,958/37,598 UTF-8 bytes under unchanged26,000/38,000 thresholds. `scripts/build-ios.sh` passed all four targets (`/tmp/writer-autonomy-final-ios.log`) and packaged30 Agent/Skill assets plus Live Activity resources were verified.

A final one-line guard prevents retaining report-start timestamps when a host disables ReplyActivity publication. Focused regression after that guard passed (`/tmp/writer-autonomy-final-guard.log`):32 Gateway/FIFO/playback cases, six listening variants, final-speech acknowledgement/coalescing and authenticated completion/stop-fence checks. The final incremental iOS app build and simulator startup are recorded below. No physical-device installation, live microphone/ASR, or real-provider drawing acceptance was performed for this change.


Final incremental MobileHarnessSimulator app build passed after the timestamp guard (`/tmp/writer-autonomy-final-app.log`), and Agent/Skill/Live Activity resource checks passed again. Installed to booted iPhone18 Pro Simulator and launched PID4348 (`/tmp/writer-autonomy-simulator-install.log`, `/tmp/writer-autonomy-simulator-launch.log`). Screenshot `/tmp/writer-autonomy-simulator.png` shows the home screen and an actual generic foundation-failure warning/retry control. Simulator system logs contain FigCaptureSource/SessionSimulator, CoreMedia format and AudioConverter preparation errors; those logs do not identify the exact app container failure. This is installation/process-launch evidence only, not a passing native voice/Writer end-to-end or fully-ready startup result. No provider request or microphone interaction was attempted. The raw simulator error snapshot was removed after recording this limited classification.


## Current-code physical-device installation (2026-11-04)

At the user's request, built the current codex/writer-agent working tree for the connected iPhone17 Pro. Signed device build passed (`/tmp/writer-autonomy-device-build.log`), and packaged30 Agent/Skill assets, Live Activity resources and deep/strict signature verification passed. Covered installation succeeded, sequence5828 (`/tmp/writer-autonomy-device-install.log`). Initial launch failed iOS security preflight (FBSOpenApplicationErrorDomain3); Developer Mode was enabled and the provisioning profile included the device and was not expired. A subsequent launch succeeded (`/tmp/writer-autonomy-device-launch-retry.log`), and process inspection confirmed PID19188 from the newly installed bundle. The first preflight failure's precise cause was not established.

This is installation and process-launch evidence, not live voice/Writer or real-model acceptance. No runtime code was changed during installation and no SQLite reset/uninstall was performed. The known coupling remains: completed Writer creative work does not await notification delivery, but its task occupancy is still retained until terminal evidence is accepted; completely independent occupancy release remains outstanding. Temporary device-details JSON was removed after selecting the capability/status fields.

## Independent creative occupancy and durable terminal notices (2026-11-04)

Writer now releases its creative slot after model/file cleanup, independently of Assistant receipt, response and playback. SQLite commits terminal run status and an immutable notification atomically. Separate Writer-owned delivery workers retire execution grants with task.result and deliver authenticated writer.completion without a taskScope; the latter cannot reopen execution/file authority. Assistant reconciles stale task views/private registries from canonical run state before new/resumed delegation, cancellation replacement and directed messages. Removed the terminal-notice/result-confirmation reply barrier. Pending terminal notices survive root/process restart; obsolete ordinary progress stops retrying after the run ends.

Focused `/tmp/writer-independent-acceptance2.log` passed the new twenty-successive-task rejection/restart fixture and all36 Assistant FIFO cases, including new/resumed delegation before old notice/control delivery and duplicate late completion. Models and UI rendering are scripted substitutes; the Gateway, scoped communication, Task/Chat SQLite and artifact operations are real. The first attempt failed because the test SQLite parent directory had not been created; the fixture now creates it explicitly. Subsequent strengthened coverage rejects execution-result receipts as well as all user notifications and checks atomic transaction rollback/independent durable receipt flags; its final results follow below.

The recreated Writer/Gateway and reopened SQLite run in the same test process; this is a restart simulation, not a measured physical app restart or native rendering test. The technical READMEs describe the new ownership, contract and persistence boundaries. No Gateway/ChannelScheduler/AgentCore scheduling changes, database reset, protocol migration, model-output cap, new directory or dependency was introduced. Builds/complete checks and physical-device evidence are recorded separately below; the earlier sequence5828 installation predates this fix.

Complete scripts/check.sh exited0 (/tmp/writer-independent-check.log):1002 IntegrationTests,161 AppWorkflowTests,225 LiveRuntimeTests and the other suites, module boundaries, six Python checks, strict format and plist validation passed. The later strengthened fixture and added transaction test passed in /tmp/writer-independent-final-focused.log: all four selected tests, including36 Assistant cases, eight Writer lifecycle cases, twenty successive tasks with both user notices and execution receipts rejected, SQLite conflict rollback/Agent isolation/independent durable receipt flags. The full run predates those final test-only additions; production behavior is unchanged between the runs. No real model was contacted.

The first build-ios.sh attempt built MobileHarnessSimulator but failed ModelKitRuntime preparation with “Some model objects have changed since the build was started” while a separate device build was running (/tmp/writer-independent-ios.log). No source fix was made for that build-system invalidation. Signed device build succeeded (/tmp/writer-independent-device-build.log); Agent/Skill assets, Live Activity resources and strict/deep signature checks passed. Covered installation succeeded on iPhone17 Pro, sequence5836 (/tmp/writer-independent-device-install.log), and fresh launch succeeded (/tmp/writer-independent-device-launch.log). The current shared database was not reset or uninstalled. Final serial iOS-script retry and process confirmation follow below; installation/launch are not real-provider or microphone/Writer interaction acceptance.

Final serial scripts/build-ios.sh retry exited0, all four targets successful (/tmp/writer-independent-ios-retry.log), with packaged Agent/Skill and Live Activity verification. Process inspection confirmed PID19219 running from the new sequence5836 installation (/tmp/writer-independent-device-process.log). No physical SQLite extraction, real model request, microphone/ASR or UI drawing interaction was performed for this acceptance; those remain separate from passing builds, scripted regressions and installation/startup. git diff --check and strict formatting of the final touched Swift/test files passed.

## Writer-owned task Island and component arbitration (2026-11-04)

Writer now publishes its own starting/running/file-step/waiting/paused/cancelling/terminal display through a root-owned latest-value worker and the existing UI.Island.present internal tool via Gateway direct. The model still sees only workspace tools. Its activity identity/session/revisions are independent of Assistant conversation and retired execution scopes. Removed the Actions task-log-derived Writer slot; changing Assistant Writer logs cannot recreate/overwrite the task Island. Terminal display follows the actual persisted terminal state, with explicit failure display if final persistence fails.

UI Island now defines background/low/normal/high/attention/critical priority ordering instead of accepting arbitrary numeric rank. Detail/status lanes, recency ties, expansion preferences, interrupted animation, layout and system projection remain UI-owned and producer-neutral. Existing local/system layout and animation code is reused. Writer only supplies display facts, semantic importance, purple icon and stage identity; display text projection preserves useful goal and step within existing UI bounds and does not trim generated files or model output.

Focused /tmp/writer-owned-island-accepted-focused.log passed five selected tests, including eight actual Writer/Gateway lifecycle cases. With all Assistant reports rejected, probes observed the real Island Action/UI state before the first model output, after file commit, and at terminal persistence; the twenty-task fixture also asserted the final independently published task display. Models and HTML rendering are scripted substitutes. Separate publisher/component cases cover unavailable delivery coalescing, old-run rejection, long display text, joined stop, voice header coexistence, manual collapse/new-stage expansion, producer-neutral semantic priority and rejection of old rank-only JSON. These do not establish native UIKit animation or real-model acceptance.

Initial compilation caught a missing ToolCall ID and an existential fixture initializer; both were corrected before the passing focused run. The first complete check stopped on the new Xcode navigation reference using a group-relative basename while this repository's navigation uses SOURCE_ROOT paths. Corrected that reference to the existing repository convention; no boundary rule was relaxed. Complete checks/build results follow below.

Final complete scripts/check.sh exited0 (/tmp/writer-owned-island-check2.log):1005 IntegrationTests,161 AppWorkflowTests,225 LiveRuntimeTests and all other suites, boundary checks, six Python checks, strict Swift formatting and plist validation passed. Opt-in real-model evaluation remains skipped. Final scripts/build-ios.sh exited0 with all four targets successful (/tmp/writer-owned-island-ios.log); packaged30 Agent/Skill assets and native Live Activity resources were verified. git diff --check passed.

No physical-device installation, simulator UI interaction, real-provider drawing, microphone/ASR or native animation acceptance was performed for this change. The earlier device sequence5836 predates Writer-owned Island presentation. No SQLite reset, new dependency/directory/module or Gateway/ChannelScheduler/AgentCore scheduling change was introduced.

## Writer task-Island physical-device installation (2026-11-04)

At the user's request, built the current codex/writer-agent working tree for the connected iPhone17 Pro, including Writer-owned Island presentation and semantic component priority. Signed device build succeeded (/tmp/writer-island-install-device-build.log). Packaged30 Agent/Skill assets, native Live Activity resources and strict/deep signature verification passed. Covered installation succeeded, sequence5844 (/tmp/writer-island-install-device.log); fresh launch succeeded (/tmp/writer-island-install-launch.log), and process inspection confirmed PID19242 running from the new installation (/tmp/writer-island-install-process.log).

No runtime code, signing configuration or database was changed/reset during this installation. This supersedes the prior uninstalled boundary for the task-Island code; it establishes installation and process startup only, not real-provider drawing, live microphone/ASR or native animation interaction acceptance.

## task_5 framing failure and Writer recovery (2026-11-04)

Read device SQLite without reset. Initial consistent base/WAL snapshots showed task_5 running after successful list and edit(index.html), with content inputE61A487F-1275-48E8-A7EC-472E8C592D84 generating. A later base snapshot contains the terminal evidence independently of WAL: immutable/read-only integrity_check=ok, task_5 failed, modelqwen3.8-max, file-content stage,431.982s, codewriter.model.stream.limitExceeded, providerStageframing. Response message204 retains15,379 characters/16,237 UTF-8 bytes and ends with </html>; no validated completion/finish reason was saved. The subsequent latest-WAL transfer failed with CoreDevice7000/socket timeout; the terminal conclusion uses the verified base snapshot, not that failed transfer. The old diagnostic cannot distinguish its8MiB cumulative guard from64KiB line/event guards. It is an application parser limit, not evidence of an HTTP error or provider quota.

Removed those generation-size guards, preserving native argument limits and bounded/backpressured event delivery; large text deltas become valid Unicode chunks. Writer now owns three-attempt transient-request recovery, corrective control/tool feedback, fresh streams after joined abort, non-replay of uncertain commit/cleanup, and complete pending-tool settlement. Failed attempts stay in SQLite with attempt evidence; recovered failures no longer mask later errors. Repeated successful calls receive advisory context without a total creative-round cap. Recovery progress comes from Writer's own Island/report path. Assistant delegation/lifecycle coupling identified in the separate audit was not changed by this fix.

Reference review used primary [DeepSeek agent-loop source](https://github.com/deepseek-ai/deepseek-harness/blob/8bd073392eef6f54e921a093b95076248eb08cbb/packages/core/agent-loop/src/agent.ts), [stream attempts](https://github.com/deepseek-ai/deepseek-harness/blob/8bd073392eef6f54e921a093b95076248eb08cbb/packages/core/agent-loop/src/assistant-stream.ts), [edit](https://github.com/deepseek-ai/deepseek-harness/blob/8bd073392eef6f54e921a093b95076248eb08cbb/packages/fs/tool-fs/src/edit.ts), [edit recovery diagnostics](https://github.com/deepseek-ai/deepseek-harness/blob/8bd073392eef6f54e921a093b95076248eb08cbb/packages/fs/tool-fs/src/error.ts) and [repeat-call reminder](https://github.com/deepseek-ai/deepseek-harness/blob/8bd073392eef6f54e921a093b95076248eb08cbb/packages/guard/repeat-tool-reminder/src/index.ts). Adopted attempt/effect separation, pending-result recovery and model-facing edit remedies; three attempts/backoff are this app's policy, not a claimed upstream default. No upstream shell, plugin framework or source-code dependency was imported. GitHub tree API was rate-limited; raw source and git ls-remote supplied the review and revision.

Focused recovery runs passed after correcting a Swift concurrency capture, fixture actor assertions and a missing brace in a test-only tool schema. /tmp/writer-recovery-acceptance2.log covers transient/permanent HTTP, three-attempt exhaustion, control correction, partial-content fresh transactions, commit non-replay and cancellable backoff. /tmp/writer-recovery-pairs2.log adds actual SQLite reopen for original failure/unexecuted sibling pairing, abort failure preservation, productive loops beyond the former limit, eight real Writer/Gateway lifecycle cases and large-SSE regression. Models/rendering are scripted substitutes. Full checks and builds follow below; no live-provider retry or automatic resumption of task_5 has been performed.

Final scripts/check.sh exited0 (/tmp/writer-recovery-check.log):1006 IntegrationTests,168 AppWorkflowTests,225 LiveRuntimeTests and all remaining suites, module boundaries, six Python checks, strict format and plist checks passed. All four scripts/build-ios.sh targets succeeded (/tmp/writer-recovery-ios.log); packaged30 Agent/Skill assets and native Live Activity resources passed verification. git diff --check and strict formatting of the final touched Swift files passed. Temporary device base/WAL/SHM snapshots and extracted conversation evidence were deleted after the metadata findings above were recorded; the device database and task/artifact history were not changed.

No real-provider regeneration/resumption, simulator/native UI interaction or physical installation was performed for this fix. The installed sequence5844 still predates the SSE/recovery change. The fixtures exercise actual local parser/Gateway/SQLite/editor paths with scripted model/rendering and cannot establish a successful live Qwen retry.

## SSE/recovery fix physical-device installation (2026-11-04)

At the user's request, signed device build succeeded for the current codex/writer-agent tree including the SSE parser and Writer recovery changes (/tmp/writer-recovery-device-build.log). Packaged30 Agent/Skill assets, native Live Activity resources and strict/deep signature verification passed. Covered installation succeeded on iPhone17 Pro, sequence5852 (/tmp/writer-recovery-device-install.log). Fresh launch succeeded (/tmp/writer-recovery-device-launch.log), and process inspection confirmed PID19290 from the newly installed bundle (/tmp/writer-recovery-device-process.log).

No runtime code, local signing settings, SQLite or artifact history was changed/reset during this installation. task_5 was not automatically resumed. This supersedes the earlier uninstalled boundary for the SSE/recovery fix; installation/startup does not establish a successful live Qwen generation or native voice/Writer interaction result.

## 本机真实模型多流程回归（2026-11-04）

新增独立专项[报告](Writer-Model-Regression.md)、[机器结果](Writer-Model-Regression.json)与[请求轨迹](Writer-Model-Regression-Requests.json)。实际Qwen3.8-max和DeepSeek-v4.1-flash各6/6通过，生产Writer/Gateway/Artifacts/SQLite与本机WebKit实际执行；源码和二进制未变，99次请求使用Provider默认输出预算。该专项还保留前轮失败及工具/内容协议修复依据，不将失败改写为首次成功。安装/真机语音与原生UI不由本机回归替代。

## 2026-11-04 Agent 自有任务岛结束

验证对象：Writer 各类终态使用 UI.Island.end 撤下自身活动，不调用 Assistant 前台任务控制、不关闭作品窗口；Assistant 根据自身 Skill 状态发布前台任务，移除 Actions 的任务日志岛投影。UI end 支持先于 present 及结束重投，保留 owner/revision 围栏。

专项命令：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'writerIsland|writerAllTerminal|assistantTaskIsland|islandEndBeforePresent'`。六项通过，日志 `/tmp/agent-island-focused.log`。覆盖所有 Writer 终态、迟到同 run 进度、旧 run、合并重投、语音活动保留、停止加入、Assistant 前台 Skill 生命周期及真实 Gateway 注册／权限／结束清理、UI 结束幂等。初次测试夹具缺失 actionCatalog、随后新 Gateway 夹具缺少 actor init await，已修正；没有伪称初次通过。均为替身／运行时自动化，无真实模型调用。

完整检查与 iOS 构建执行结果在本节续记。未安装或操作真机，未读取／清空真机 SQLite；完成后实际视觉、语音及系统 Live Activity 撤下仍需设备验收。

第一轮完整检查主回归出现两项旧契约断言失败：Assistant internalTools 为空、Actions 根据 Home Task 日志生成任务岛；已替换为内部展示权限不暴露模型和日志不得重新生成活动的断言。随后完整检查主回归 1017 项通过（约64秒），Writer 12种生命周期、通知拒收后连续20任务均通过；原生阶段和 iOS 构建最终退出码在下文记录。

最终 `./scripts/check.sh` 退出0，日志 `/tmp/agent-island-check-final.log`：主集成1017项通过，独立原生阶段225项通过（约206秒），其余包测试、架构边界、Swift格式和plist检查通过。`git diff --check` 通过。原生阶段结束后串行执行 `./scripts/build-ios.sh`，避免并行构建干扰实时测试。

最终 `./scripts/build-ios.sh` 退出0，日志 `/tmp/agent-island-ios.log`：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四目标全部构建成功，应用 Agent/Skill 与 Island 扩展资源检查通过。iOS 条件编译的 AgentRuntime 订阅显式捕获 AssistantExecutionSession，不额外捕获根所有者；该路径由此构建验证。以上没有执行新的真实模型、模拟器手动交互或真机视觉验收。
