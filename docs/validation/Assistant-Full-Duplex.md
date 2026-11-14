# Assistant 全双工与 Decision 验证

日期：2026-11-10。基线 a7d1bf31；本报告对应工作区实现，未提交或发布应用。环境为 macOS 27.2、Xcode 27 工具链、Swift 6.4。需求及历史方案见 [多源输入协调](../requirements/Assistant-MultiSource-Input-Coordination.md)。

## 范围与方法

- 替身模型与执行门闩验证整 Q 一次冻结、生成与 Action 独立、跨轮同 channel FIFO、原生工具结果配对合并、打断与暂停后的清理/恢复。
- Decision 替身验证短上下文、唯一强制工具、非法/缺失/重复结果、超时、本地缺失回退、保护交互答案和空闲时归一化；不代表真实云端模型分类准确率。
- SQLite 验证增量升级保留旧输入；输入终态与单次模型生成终态分开保存，批次成员保留各自原文与关联。
- Python 下载目录测试核对 D3 注册、固定版本、原生目录制品。远端文件清单已核对12个必要文件、合计1,013,189,709字节；应用完整下载/断点续传/删除的原生 UI 验收另列。

## 真实 D3

制品：hugging-mac/d3-edge-CoreAI，revision `0690c04ee1640c1c3fa11a882323751dda6d086a`。权重位于已批准的仓库外目录，未加入本仓库。

`D3_TEST_RESOURCES=/Users/devil/Pro/d3-edge-coreai/runtime-models` 启用真实 Swift tokenizer/Core AI 测试；普通自动测试不需要模型文件。固定 billing 样例选择与已发布分数一致（容差0.03），超512 token拒绝。首次验证热调用约0.060秒，包含该测试的冷启动总计约29.2秒；这是此 Mac 的单次样本，不能当作 iPhone 延迟指标。

历史转换实验的48条中文业务样例最高35/48；属于调提示词使用过的合成数据，不是独立测试集。转换数值一致不等于业务准确。应用默认云端，本地需手动选择，页面标明实验性质。新增8条原生业务探测按当前请求格式得到5/8：简短回答“嗯”误判 discard，否定停止和引用 stop 误判 interrupt。测试通过只表示正常执行，不表示业务验收通过。本次两个原生测试均正常完成，总计10.464秒；热调用0.097秒（两个原生用例同进程运行），不作为独立性能基准。

## 自动检查与构建

- `scripts/check.sh` 已完整运行。边界检查、7个下载测试、Swift格式和plist校验通过。第一阶段各测试目标均通过，其中Integration为1127个测试；第二阶段229个运行时测试出现相机绘制超时与麦克风门控序列错误，因此完整检查不能标为通过。
- 麦克风失败定位为不支持全双工的订阅重置了先前播放等待状态，修复后 `directMicrophoneConsumptionPreservesNativeSequenceAcrossGating` 通过。最终专项9个测试全部通过，覆盖该门控及批次、暂停、打断、跨轮FIFO、配对合并、独立容量和异步封口失败；此前Decision工具及回退专项也通过。
- 相机 `cameraNativeMetalDrawStopAndLayerHandoff` 全量运行5秒超时。单独复跑进程退出0，但只输出started，没有passed/failed完成记录，故仍记为未获通过证据；本次没有改动相机renderer来绕过该问题。
- 最终边界检查、Swift lint、diff格式和变更Markdown文件链接检查通过。`scripts/build-ios.sh` 的 MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个模拟器目标及资源校验通过。另行运行 `xcodebuild -scheme MobileHarness -destination generic/platform=iOS -derivedDataPath build/DeviceDerivedData CODE_SIGNING_ALLOWED=NO build`，通用iOS设备目标编译成功；上述脚本本身不构建设备目标。该次通用目标构建未签名；后续签名安装见本报告末节。

此前失败与修正保留：D3配置字段命名不符合 Swift lint 已修正；全双工追加批次误用于普通续轮，破坏最后执行观察，已限定到合并批次；批次终结提前删除回复占用导致结束通知遗漏，已修正；旧同 channel 跨输入并发测试与新 FIFO 契约冲突，已改为验证等待。旧运行因未释放的测试门闩被终止，不计通过。任务切换的历史投影误删当前输入但保留引用摘要，已限定多成员批次并清除相关摘要；专项复测通过。新增容量测试最初使用了错误的fixture类型断言，修正后通过。并行重负载时的短时断言失败须与复测结果区分。

## 未完成的真实验收

- 真实云端服务的分类结果、时延、工具调用兼容性及费用未在本次发送请求验证。
- 物理 iPhone 可见，但尚未完成外放回声、用户重叠讲话、蓝牙切换、录音权限/打断恢复、采集与播放连续性的实际声音验收。
- Decision 下载页、双字幕与队列计数的原生交互及完整网络下载尚未操作验收。
- 本地 D3 尚无满足业务准确率的独立真实语音转写评测；不得用本次编译/替身/原生执行通过替代。

## 人工验收场景（2026-11-10 基线）

下表保留基线预期。后续版本的执行等待、用户输入缓冲及 ReACT 合批验收见 [Channel 结算验证](Assistant-Channel-Settlement.md)。

| 场景 | 预期行为 |
| --- | --- |
| 播放中说“停一下” | final进入Decision；判interrupt后停止旧LLM及会话执行，整Q进入下一轮。 |
| 播放中说“讲完再说上海”及另一个Agent消息 | 分别分类并排队；下一请求包含全部待处理输入及来源/时间。 |
| “嗯”作为附和或问题答案 | 根据短现场区分；有效交互答案必须保留，partial不清助手字幕。 |
| LLM结束但相机Action尚未结束 | 新输入可以启动LLM；同channel新Action等待旧Action实际完成。 |
| 本地模型缺失、加载中、删除或超长输入 | 页面显示实际云端回退；云端也失败则保守入队。 |
| 暂停、打断后收到迟到结果 | 不启动旧续轮；记录原调用结果或取消/效果未知，不重放设备效果。 |

## 2026-11-10 真机交付

用户要求安装当前工作区到真机。沿用被忽略的本地签名配置，在现有 build/DeviceDerivedData 签名构建0.1.0（2026111008），BUILD SUCCEEDED；严格深层签名、33项Agent/Skill资源及Live Activity扩展校验通过。

已原位安装到已配对的 iPhone 17 Pro，安装流水6544；设备应用清单确认从2026111007更新为2026111008，系统启动请求成功。未卸载应用、清空数据或改动仓库签名设置。安装启动不替代真实语音、分类质量与页面交互验收。

本机证据：`/tmp/duplex-signed-device-build.log`、`/tmp/duplex-device-install.json`、`/tmp/duplex-device-launch.json`、`/tmp/duplex-device-apps-after.json`。

## 2026-11-10 历史双方完整文本

请求详情改为读取独立持久化的完整业务输入，包括 Q 批次与合并续轮观察；完整回复保留原文，详情不限制行数，列表仍使用预览。原始输入和来源关联继续保留。旧批次仅从成员身份全部吻合的尚存日志恢复，缺少日志时不能补回既往文本。

新增真实 SQLite 回归覆盖接纳时写入、后续 checkpoint、数据库重开、清理日志，以及 message/read/window/input 和 UI 详情投影的完整性；旧记录兼容覆盖 messages、responses、成员不匹配和日志已清理四种情况。合并原生结果测试同时验证新输入与执行观察均被留证。首次专项编译发现测试缺少 MainActor await，修正后10项专项测试通过。

本次 `scripts/check.sh` 返回0：边界、下载7项、Swift格式、plist及第一阶段全部目标通过，Integration 1131项通过；第二阶段 LiveRuntime 229项通过。NativePresentation 的相机绘制仍只有 started、没有完成记录，不能将脚本返回0解释为该用例已获通过证据。文档本地链接及 diff 格式检查通过。日志：`/tmp/duplex-history-tests.log`、`/tmp/duplex-history-check.log`。原生历史页面的实际目视验收不由存储与投影测试替代。

`scripts/build-ios.sh` 四个模拟器目标及资源校验通过；MobileHarness 真机签名构建0.1.0（2026111009）通过，深层严格签名、33项Agent/Skill资源和Live Activity扩展校验通过。已原位安装至同一 iPhone 17 Pro，安装流水6552，设备应用清单确认版本2026111009；现有数据未清空。第一次连接查询被设备重置，重试成功。安装后的启动请求被设备锁屏拒绝，未宣称已启动或完成真机页面验收。

本机证据：`/tmp/duplex-history-ios-build.log`、`/tmp/duplex-history-device-build.log`、`/tmp/duplex-history-device-install.json`、`/tmp/duplex-history-device-after.json`、`/tmp/duplex-history-device-launch.log`。

## 2026-11-10 空回复输入记录定位与中间方案（已被请求边界方案替代）

用户截图中的“拍一张啊。”在真机数据库只读副本中对应 assistant_messages.id=326：state=completed，coordination.decision=discard，route=local:d3-edge，source=speechPerception；没有模型 invocation 或回复。SQLite quick_check=ok。由此确认该条是本地分类丢弃的输入，不是已调用 LLM 丢失回复。历史 page/message 先前将原始输入包装为模型请求，UI 又丢弃 coordination，造成空回复和缺失上下文的假象。

此中间方案保留原始输入，随后被用户明确要求替代，以下仅保留当时验证经过。未修改用户的 Decision 模式或重放拍照指令。Storage 查询区分真实输入和模型调用；UI 显示输入处理结果、三类决策、来源、采集时间标记及批次关联。真实模型调用无输出时显示实际状态。输入 error/finishReason 随业务 JSON 保存，输入失败不依赖生成日志。拍照指令的本地误丢弃仍属 D3 业务准确率问题，本修复不宣称解决分类质量。

专项回归通过：输入-only 的9种场景、真实空模型请求的5种状态、旧批次日志恢复4种场景、完整文本持久化，以及2项既有 UI 投影测试。真实 SQLite 验证 page/message、日志清除、导出和错误保留；未操作原生详情页面，不能将 DTO 投影测试视作原生目视验收。日志：`/tmp/duplex-empty-tests.log`。数据库副本仅用于定位，未加入仓库。


## 2026-11-10 Message 实际请求边界

最终约束以用户确认为准：discard 只做前端瞬时提示；排队、分类及请求准备不产生 message 或模型请求日志。Assistant 和 Writer 在云端 HTTP 发送、本地推理开始的回调处创建一条请求记录，后续回复、失败、打断更新同一条。Writer 委托执行状态独立保存在 writer_executions。批量输入的 decision、来源、时间随实际请求保存。

Schema 20261112 从20261110/20261111事务迁移：保留真实 invocation 主键、业务结果、日志和工作区，迁出 Writer 委托，删除无 invocation 的原始输入行；外键检查通过后才提交。日志清理后的真实请求仍保留。旧版本曾在准备阶段创建的 invocation 无法仅凭空回复判定是否发出，迁移保守保留。

回归扩展覆盖零请求零消息、丢弃提示但不调用主模型、队列整批一条记录、重复开始回调、网络失败保留、请求身份发布失败重试、Writer 委托与模型请求分离，以及两种已安装 schema 迁移。检查、补充回归与构建结果见下文。

首次全量检查 `/tmp/message-boundary-check.log` 中消息边界、迁移、Writer 与 HTTP dispatch 回归通过；Integration 1134项中只有既有 `slowTrackingDispatchExecutesOnlyTheNewestPendingTarget` 的第二个跟踪角度断言失败。LiveRuntime 229项通过，NativePresentation 相机绘制仍只有 started、无完成记录。脚本返回1，不视为全量通过。最终代码复查的并发阶段再次出现同一断言失败，后续单独复测、构建和安装结果另记。

最终 `scripts/check.sh` 返回1：边界、下载7项、格式、plist检查通过，Integration 1134项仅上述跟踪角度断言失败，LiveRuntime 229项通过；相机原生绘制用例仍缺完成记录。`swift test --filter slowTrackingDispatchExecutesOnlyTheNewestPendingTarget` 在空闲阶段独立复测通过（0.044s），未修改该用例或机械臂代码，不能据此把全量结果改写为通过。最终日志：`/tmp/message-boundary-check-final.log`、`/tmp/message-boundary-tracking-retest.log`。Markdown本地链接与 git diff --check 通过。

末轮 UI 复查发现字幕槽 notice 会在助手回复非空时隐藏，补充为中立 placement=toast 并在导航外层呈现。`/tmp/message-boundary-toast-tests.log` 的7项专项回归通过（3项请求边界、4项提示/字幕/错误/到期），受影响Swift格式与diff检查通过。此前全量检查的结果仍按上文记录；原生 toast 目视不由状态测试替代。补充后重新执行模拟器四目标与真机签名构建，安装使用重建产物。

最终 `scripts/build-ios.sh` 四个模拟器目标全部 BUILD SUCCEEDED，33项Agent/Skill资源与Live Activity扩展检查通过。真机签名构建0.1.0（2026111010）通过，深层严格签名及相同资源检查通过。末轮模块边界检查、受影响Swift格式、本地Markdown链接与diff格式通过。构建证据：`/tmp/message-boundary-ios-build-final.log`、`/tmp/message-boundary-device-build-final.log`、`/tmp/message-boundary-final-boundaries.log`。

已原位安装至同一 iPhone 17 Pro（安装流水6560），设备清单确认版本2026111010，启动请求成功。启动后只读核对数据库副本：schema=20261112、quick_check=ok、外键违规0；Assistant/Writer无 invocation 的消息行均为0；截图对应旧 id=326 已不存在，独立 writer_executions 有16条。副本核对后删除，仅保留不含用户正文的检查摘要。此结果验证真实设备迁移，不代表真实D3分类质量或原生toast目视验收。

安装/迁移证据：`/tmp/message-boundary-device-install.json`、`/tmp/message-boundary-device-apps.json`、`/tmp/message-boundary-device-launch.json`、`/tmp/message-boundary-live-validation.json`。现有真实请求、工作区及委托继续使用原库；没有卸载或清空应用数据。

## 2026-11-10 表情成功无返回值核对

根据用户澄清，修正统一 Q 设计为“Action 有业务返回值或执行异常才产生输入；成功 Void 不产生输入”，撤回将内部完成回执误说成表情成功返回值的循环推断。现有 express / setExpression 均 async throws -> Void，completed.hasBusinessOutput=false；真实异常保留，用户主动取消不伪装为失败。未修改运行代码。

`generationRoundVoidSuccessStopsAndFailuresContinueWithoutReplay` 的6个 Action/Tool/混合、成功/失败用例全部通过：成功无值只请求一次，执行失败才续轮，原 Action 不重放。证据 `/tmp/expression-void-regression.log`；设计链接、JSON示例及diff格式通过。本次是代码核对、既有回归与文档修正，不新增真机验收结论。

## 2026-11-11：用户专属 Decision 与统一语义批次

实现范围：用户 ASR final/manual input 才调用 Decision；已认证 Agent 消息及 Action 业务值/异常直接进入同一有界 Q。单条与多条统一使用 assistant.input_batch.v1，保留角色、来源、UTC 时间、seq 和用户精简分类标签。普通 Action 不等同轮其他执行结束，native 组配对齐备即可入 Q；成功 Void 与纯取消不产生语义消息。准备失败保留内存批次，新用户输入允许合并重试；真正 dispatch 才创建 message。提示词支持选择性/合并回复与仅表情。

新增/调整的自动化证据：
- InputDecisionTests：三条用户输入恰好三次分类、Writer 消息零分类；多条 ASR 按事件时间排序，不能假设它们必然早于 Agent 接收时间。SQLite 直接 COUNT 验证一批一行；每项的 decision/decision_route 随批次保留。手工输入与 ASR discard 都无主请求/SQL 行。
- PreparationRetryModel：配置准备失败不建行、不热重试；下一条用户输入携带原批次一起发送，仅真实发出的一次请求建行，未发准备失败不进入聊天历史。
- GenerationRoundTests：普通 Action 的业务值/异常在另一 Action 尚未完成时发起新请求；全程仅初始用户输入调用 Decision。native 两个结果配对后不等无关 Action，配对和结果各保留一次。
- 队列容量测试覆盖 text 与 ASR：一个业务结果与 31 条用户输入占满 32 个语义槽；原轮内部结算另占保留槽，第 33 条语义输入明确拒绝。ASR 不误算为后台 Agent 的 16 条限额。
- 原有整 Q、输出 FIFO、打断、暂停、成功 Void/真实失败六组合继续回归。完整 batch/协议附件为受保护输入，准备失败不截断正文。

迭代中发现并修正：新提示词曾超过摄影场景 38,000 字节预算，精简后 base=24,343、photography=37,892；旧容量断言仍按执行结果不占语义槽编写，已按统一 Q 更新；ASR 测试此前错误假定 Agent 接收时间晚于全部 ASR，改为校验真实时间排序与 ASR 相对顺序。一次完整检查的 toast 到期时序断言失败，不作为本次队列实现通过的证据；以最终复核结果为准。

最终检查证据：
- `./scripts/check.sh`：边界检查、Python 7 项、全仓 Swift 严格格式、1138 项集成测试、229 项原生运行测试与 plist 校验通过；该次脚本 exit 1 的唯一剩余失败是旧 toast 固定等待断言。原生相机 `cameraNativeMetalDrawStopAndLayerHandoff` 仅见 started，无完成结果，不计为原生 UI 验收通过。
- 改为有截止时间的状态等待后，AppWorkflowTests 全部 185 项通过。随后补齐非 Decision 入队/准备失败入队的 UI 排队事实刷新，最终 12 项相关集成回归与 185 项 UI 回归再次通过；日志 `/tmp/multisource-ui-queue-recheck.log`。完整阶段日志 `/tmp/multisource-check-final-v2.log` 保留此前失败，不将其改写为 exit 0。
- 最终源码边界与格式单独复核；准备失败、来源/时间/分类标签和 SQLite 一批一行都由可观察行为断言覆盖。

自动化替身验证不代表真实云端/D3 分类准确率、持续语音体验或原生 UI 验收。iOS 构建与安装证据在以下追加。

iOS 与设备交付：
- `./scripts/build-ios.sh` 四个目标 MobileHarnessSimulator / ModelKitRuntime / ModelKitNemotron / ModelKitSilero 均 BUILD SUCCEEDED，exit 0；日志 `/tmp/multisource-build-ios.log`。
- 最终增量真机签名构建成功，`codesign --verify --deep --strict` 通过；33 项 Agent/Skill 资源及 WidgetKit 灵动岛嵌入、版本/身份校验通过。日志 `/tmp/multisource-device-final.log`。
- 已安装并启动 iPhone 17 Pro（UDID `00008150-000579D114C2401C`）上的 `dev.mobileharness.app`，设备查询版本为 `0.1.0 (2026111101)`，安装序号 6568。安装、启动、版本证据分别在 `/tmp/multisource-device-install.log`、`/tmp/multisource-device-launch.log`、`/tmp/multisource-device-app.log`。
- 本次没有触发真实云端/D3 对话，未将安装启动、替身测试或原生运行用例当成连续语音/选择性表情体验验收。工作区修改未提交。

## 2026-11-11：Decision 独立 Provider/模型配置

Decision 页面独立选择本地 D3/云端，云端 Provider/模型沿用共享 Provider 注册表与发现交互，配置通过既有私有事务持久化。运行时只解析 Decision 自身绑定，本地失败回退同一绑定；旧文档缺少字段读作未配置，不跟随 Assistant。未配置或失败保守入队，message 的请求边界不变。

自动验证：
- 针对性回归 `/tmp/decision-provider-targeted.log`：10 项集成回归及 2 项表单回归通过，涵盖本地失败/云端短上下文分类、独立 Provider/模型、文档重开及旧字段缺省、无效引用/空白/超长模型拒绝、实际 UI 私有保存恢复与呈现、Provider 删除及角色选择互不覆盖。
- `./scripts/check.sh` exit 0，证据 `/tmp/decision-provider-check.log`：源码边界、Python 7 项、Swift 全仓严格格式、1140 项集成测试、186 项界面流程测试、其余通用测试、229 项 LiveRuntimeTests 和 plist 校验通过。
- NativePresentationTests 的两个过期状态测试通过；cameraNativeMetalDrawStopAndLayerHandoff 仍仅输出 started、未输出完成结果。即使脚本 exit 0，也不将其记录为原生相机或新增 Decision 页面验收通过。
- `git diff --check` 通过。没有调用真实云端服务或验证 D3 分类准确率；上述凭据/模型测试使用替身。

构建和设备交付证据在下方追加。

- 真机签名构建 exit 0，`codesign --verify --deep --strict` 通过；33 项 Agent/Skill 资源及 WidgetKit 身份/版本/嵌入检查通过。日志 `/tmp/decision-provider-device-build.log`。
- 覆盖安装并成功启动 iPhone 17 Pro 上的 `dev.mobileharness.app`，设备清单确认 `0.1.0 (2026111102)`，安装序号 6576；没有卸载或清空数据。证据 `/tmp/decision-provider-device-install.log`、`/tmp/decision-provider-device-launch.log`、`/tmp/decision-provider-device-app.log`。
- 安装启动不代表 Decision 原生页面人工操作或真实云端/D3 分类验收；旧配置需要在 Decision 页面显式选择云端 Provider/模型。
- `./scripts/build-ios.sh` exit 0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个目标全部 BUILD SUCCEEDED；模拟器包 Agent/Skill 和灵动岛资源检查通过。日志 `/tmp/decision-provider-build-ios.log`。

## 2026-11-11：回声消除输入与固定双方字幕

实现：对话优先尝试系统 echo-cancelled input，读取实际启用结果；不支持/未启用/失败时回退 voiceChat + 双 I/O voice processing，明确关闭 bypass。采集启动及首帧就绪后、每次播放提交前验证所选 AEC；路由通知优先检查 AEC 是否丢失。AudioCaptureContext 记录真实路径，未启用时沿用受限模式。用户字幕固定上方，助手字幕固定下方，移除定稿上飘，布局与 Channel 活动无关。

证据边界：旧版已有语音处理开关，本次发现缺少双节点/bypass 和启动后验证、失败被吞掉；没有拿到旧版实际音频测量，不能据此断言回录根因已证实。系统 AEC 是否开启不等于扬声器场景的真实抑制率；也不使用文本相似度丢弃可能真实的用户插话。

- `/tmp/duplex-aec-targeted.log`：9 项集成回归通过（AEC 选择、原生错误保留、未支持/未启用回退、已有全双工队列与打断），字幕布局回归 1 项/5 种高度通过，覆盖 320/568/667/852/1024 点上下分离与边界。
- `/tmp/duplex-aec-device-build.log`：iPhone 真机签名构建 BUILD SUCCEEDED、exit 0，版本 2026111103。
- 真机声学验收步骤：内置扬声器中等/高音量播报时保持静默，确认不把播报写为用户 final、不触发循环；播报同时说新的指令及“停一下”，确认用户内容能被识别和打断；切换耳机/扬声器及停止后重启，核对新代 AEC 状态和受限提示；长文本与连续 ASR 下确认上下字幕不换位。
- 上述声学/页面人工验收尚未执行，不以配置替身、编译或安装代替。完整检查与安装结果在下方追加。

最终验证与交付：
- `./scripts/check.sh` exit 0，`/tmp/duplex-aec-check.log`：边界检查、Python 7 项、全仓 Swift 严格格式、1143 项集成测试、186 项界面流程测试、其余通用测试、229 项 LiveRuntimeTests 及 plist 校验通过。NativePresentationTests 的相机 Metal 用例仍只见 started，无完成结果，不计为原生 UI 验收通过。
- `./scripts/build-ios.sh` exit 0，四个目标全部 BUILD SUCCEEDED，日志 `/tmp/duplex-aec-build-ios.log`。真机签名深度严格校验、33 项 Agent/Skill 资源、WidgetKit 身份与嵌入校验通过。
- 覆盖安装并启动 iPhone 17 Pro 的 `dev.mobileharness.app`，设备查询为 `0.1.0 (2026111103)`，安装序号 6584。安装/启动/版本证据：`/tmp/duplex-aec-device-install.log`、`/tmp/duplex-aec-device-launch.log`、`/tmp/duplex-aec-device-app.log`。未卸载或清空数据。
- `git diff --check` 通过。设备扬声器回录、双讲抑制效果与固定字幕目视验收仍按以上步骤进行；未采集或保存用户音频作为本次验证证据。

## 2026-11-11：Decision 灵动岛反馈

- 集成回归验证 enqueue 不创建活动，discard 只发布反馈且无模型请求、无 message，interrupt 在旧动作退出后发布反馈并保留新输入。另验证两种反馈的本地自动展开、新结果覆盖、系统活动选择保持及结束后恢复原任务详情。测试替身提供固定分类结果。
- 第一轮回归曾要求打断反馈发布时历史终态已经写回。实际打断流程先加入旧执行取消，历史由随后结算的旧轮写回。断言已改为验证旧动作退出，同时独立验证历史最终取消和新输入完成。
- 四个 iOS 构建目标均通过，日志 `/tmp/decision-island-build-ios.log`。真机签名和资源核对通过。iPhone 17 Pro 已覆盖安装并启动 `0.1.0 (2026111104)`，安装序号 6592，证据见 `/tmp/decision-island-device-{build,install,launch,app}.log`。
- 真机实际语音定稿、录音状态撤下与展开动画之间的衔接尚未目视验收。建议分别触发丢弃、打断和入队，并在反馈展开期间开始下一句，核对上一句结果和下一句状态能够独立更新。
- `/tmp/decision-island-check-release.log` 中三条 Decision/灵动岛回归及 229 项原生运行测试通过。全量集成阶段有一项已有云台跟踪断言失败，故检查脚本未通过。该用例随后单独通过，日志 `/tmp/decision-island-tracking-recheck.log`。

## 2026-11-11：模型请求多轨自然文本

- 实际模型请求替身检查 User Input、Action Result、Agent Message 标题、每条时间与来源、ASR 顺序、业务内容及内部标识缺失。数据库原始 coordination JSON 独立保留三条已分类输入的路径及关联，整批只创建一条已发起记录。
- 旧历史回放回归覆盖批次在首行、夹在结果之间及同记录多个批次。回放去掉内部标识，内嵌伪标题作为续行保留。提示词同时包含 INPUT FORMAT 与 OUTPUT FORMAT，基础和摄影上下文低于既有预算。
- `/tmp/channel-text-build-ios.log` 四个目标构建通过。真机最终签名构建 `/tmp/channel-text-device-final.log` 通过。签名、33 项 Agent/Skill 资源和 WidgetKit 嵌入均已核对。设备查询确认覆盖安装 `0.1.0 (2026111105)`，安装序号 6608。锁屏阻止远程启动，日志 `/tmp/channel-text-device-launch.log`。实际模型/语音与岛动画仍待真机验收。
- 最终主应用模拟器增量构建 `/tmp/channel-text-simulator-final.log` 与资源复核通过。全量脚本 `/tmp/channel-text-check-final.log` 完成，正文、提示词、协调持久化及 Decision 灵动岛相关用例均通过。1145 项集成测试中仅既有云台跟踪断言失败，该用例单独复测通过（`/tmp/channel-text-tracking-recheck.log`）。229 项 LiveRuntimeTests 通过。NativePresentationTests 相机 Metal 用例仅有启动记录，未作为原生呈现通过证据。格式与 diff 校验通过。

## 2026-11-11 前台任务结束

- 真机数据库与 WAL 的只读核对显示，受影响的前台任务已关联原始 Message，结束 Action 有成功回执，任务仍为 running 且摘要为空。检查未改写真机业务数据。
- `fullDuplexTaskEndPersistsAndFoldsWhileGenerationAndAnotherChannelAreRunning` 使用模型流和显示 Action 替身、真实 ChannelScheduler 及 SQLite。两者都未结束时，Control 已提交任务和摘要并释放 Skill。放行模型流后原 Message 保存回复；放行 Display 后同一行补齐两个 Action 的记录。折叠包含启动、过程和结束 Message，原始历史仍可读取。修正测试读取边界后，该回归在全量脚本第一轮通过。
- 首次全量检查出现一项提示词措辞断言、云台跟踪和提前 Action 结果的并发断言失败（`/tmp/mobileharness-foreground-end-check.log`）。修正提示词后复跑，第一阶段 1146 项集成测试通过，包含上述失败用例及前台结束回归（`/tmp/mobileharness-foreground-end-check-final.log`）。
- 最终 `./scripts/check.sh` 退出 0，LiveRuntimeTests 229 项通过，边界检查、格式与 plist 校验通过。相机 Metal 用例在日志中仅有启动记录，未计作验收。 `git diff --check` 通过。
- `./scripts/build-ios.sh` 四个目标构建通过。BasicSkill 提示词最终修改后增量重建主应用，33 项 Skill 资源与 WidgetKit 嵌入复核通过，包内 BasicSkill 指令与源码逐字节一致。
- 真机签名构建及深层严格签名验证通过，33 项 Skill 资源、WidgetKit 和最终 BasicSkill 指令核对通过。iPhone 17 Pro 覆盖安装并成功启动 `0.1.0 (2026111106)`，设备清单确认版本，安装序号 6672。此次验证覆盖安装和进程启动，实际模型任务关闭未复测。日志位于 `/tmp/mobileharness-foreground-end-device-{build,install,launch,app}.log`。

## 2026-11-13 打断回复后保留拍照任务

- 真机 SQLite 的 `task_6` 在旧回复播放被打断后以 `cancelled` 结束，`summary` 为空。随后 `Camera.Capture.close` 成功，关相机的 Message 无任务归属。
- `fullDuplexInterruptedReplyPreservesPhotographyTaskAndPersistsSummary` 通过。使用脚本模型、阻塞的旧轮 Action、实际 AssistantExecutionSession、Gateway 和 SQLite，检查打断留在旧消息，新输入仍绑定同一任务，收到关相机结果后由 `task.end` 写入完成状态和非空摘要。原始消息及摘要来源均可查询。
- 最终 `./scripts/check.sh` 退出 0。第一阶段 1146 项集成测试通过，设备与原生运行套件 228 项通过，边界、格式和 plist 校验通过。`git diff --check` 通过。
- `./scripts/build-ios.sh` 的四个 iOS Simulator scheme 均构建通过，主应用资源和 WidgetKit 校验通过。该修复尚未进行真机交互复测。

## Decision 原文与任务结束入口

- 手工输入和语音最终文本走同一 Decision 日志路径。替身分类器验证被丢弃输入的原文仍与决策同条保留。UI 状态回归验证原文随相同记录身份保留。
- 前台回归覆盖关闭会话、打断、模型失败和重复启动。明确 `task.end` 可提交终态及摘要。Writer 回归覆盖正在生成和等待补充时接收取消消息、终态原因保存、清理及拒绝已取消执行继续选择工作区。
- `./scripts/check.sh` 退出 0，第一阶段 1144 项集成测试通过，设备与原生运行套件 228 项通过。格式、边界与 plist 检查通过。`git diff --check` 通过。
- `./scripts/build-ios.sh` 四个 iOS Simulator scheme 构建通过，主应用资源和 WidgetKit 校验通过。尚未在真机交互复测。

### 结束入口清理复验

- 移除旧前台终态写入及未用参数后，`./scripts/check.sh` 退出 0。第一阶段 1144 项集成测试和设备与原生运行套件 228 项通过。检查覆盖拍照摘要、Writer 新旧取消记录以及 Decision 原文。
- `./scripts/build-ios.sh` 四个 scheme 构建通过。`git diff --check` 通过。

### 前台重试与 Writer 正文转述复验

- 验证 BasicSkill 提示词覆盖控制失败后的状态检查与重试，以及继续意图不明确时询问和明确转向时结束。工具目录校验 `task.send` 只接受目标和正文。
- Writer 的脚本模型及 SQLite 回归覆盖正在生成和等待补充时收到明确停止消息，以及普通转述由 Writer 私有模型选择 `finish(outcome=cancelled)`。终态保留取消原因，普通补充仍按待答身份处理。
- `./scripts/check.sh` 和 `./scripts/build-ios.sh` 退出 0，`git diff --check` 通过。该版未在真机或真实模型上复测。

### 前台控制与后台定向通信

- 目录回归验证 `task.send` 缺少 `agent_id` 或 `text` 时拒绝。活跃前台任务期间，运行时拒绝无目标或以 Assistant 为目标的发送，保留原任务，直至 `task.end` 提交摘要。
- Writer 脚本回归验证委派与前台任务可并行。前台结束后，原 Writer 委派仍活跃，可接收停止正文并独立提交终态。
- `./scripts/check.sh` 退出 0，1144 项集成测试及 228 项设备与原生运行测试通过。`./scripts/build-ios.sh` 四个 iOS Simulator 目标构建通过，包内 BasicSkill 指令与任务反馈资源和源码一致。未进行真机或真实模型复测。

### 单一后台消息入口

- 脚本模型和 SQLite 回归覆盖仅通过 `task.send` 启动任务、匹配活跃补充、拒绝独立新目标及过期待答、保存取消原因、持久终态和前台独立性。专项复跑的四组测试通过，共 56 个参数化场景。
- `./scripts/build-ios.sh` 退出 0，四个 iOS Simulator 目标、46 项 Agent 与 Skill 资源及 Live Activity 校验通过。`./scripts/check.sh` 退出 1，1147 项集成测试中的同一输入分类计数用例有两个参数场景失败，两者专项复跑通过。228 项设备与原生运行测试通过。`git diff --check` 通过。未运行真实模型或真机验收。

### 后台消息与统一回报契约

- `agent.task.message` 用于发送正文，`agent.task.report` 用于回报。脚本模型、Gateway 和 SQLite 回归覆盖忙碌拒绝与过期追问答复的持久重投、事件身份稳定、拒绝不改变原任务终态，以及新旧终态记录的领取和重试上限。
- `./scripts/check.sh` 退出 0，1147 项集成测试及 228 项设备与原生运行测试通过。最终变更后的五组专项测试通过。`./scripts/build-ios.sh` 四个 iOS Simulator 目标及应用资源校验通过。`git diff --check` 通过。未运行真实模型或真机验收。

## 2026-11-11 Assistant 输入时间线

- 模型请求替身和 SQLite 回归核对正文在前、来源与本地秒级时间在后、跨来源事件顺序、同秒内稳定排序，以及 User Request 保存实际发送的正文。原生工具配对、Action 结果提前就绪及前台任务结束回归覆盖原有执行路径。
- 输入协议预算回归通过，基础目录为 24,380 字节，摄影目录为 37,929 字节。验证范围包括协议样例与 ASR 澄清措辞，实际模型的纠错和澄清效果待真实输入验证。
- `./scripts/check.sh` 退出 0，集成套件 1147 项、LiveRuntimeTests 229 项及相机 Metal 用例通过。补充历史回放识别后，6 项相关测试重跑通过，包含旧 JSON 被引用时保留原正文的断言。日志位于 `/tmp/mobileharness-signal-format-{check,targeted-final}.log`。
- `./scripts/build-ios.sh` 四个目标构建通过。补充历史回放识别后重建主应用，33 项 Skill 资源、WidgetKit 和包内 Assistant/Prompts.json 与源码一致性核对通过。日志位于 `/tmp/mobileharness-signal-format-{ios,ios-final}.log`。

## 2026-11-11 多来源回应优先级

- 系统提示词回归核对时间线样例、最新用户修正、多来源证据、ASR 关键疑义澄清和回应优先级。基础目录 24,418 字节，摄影目录 37,967 字节，在原预算内。批次回归将 ASR 采集时间固定在同伴接收之前，避免异步投递耗时改变测试构造的事件顺序。
- 第一次全量检查发现批次夹具的时间锚点问题后中止；修正后全量脚本退出 1。1147 项集成测试中，Writer 窗口、相机首帧、云台跟踪和三项诊断呈现共六个用例失败。上述六项与三个提示词及批次用例一并专项复跑，九项全部通过。LiveRuntimeTests 229 项通过，相机 Metal 用例仅有启动记录。日志见 `/tmp/mobileharness-signal-priorities-{check,check-final,targeted}.log`。
- `./scripts/build-ios.sh` 四个目标构建通过，33 项 Skill 资源和 WidgetKit 复核通过，包内 Assistant/Prompts.json 与源码逐字节一致（`/tmp/mobileharness-signal-priorities-ios.log`）。
- 真机签名构建、深层严格签名及资源核对通过。iPhone 17 Pro 已覆盖安装并成功启动 `0.1.0 (2026111107)`，设备清单确认版本，安装序号 6680。此次验证覆盖安装和进程启动，真实模型的取舍和澄清效果未复测。日志见 `/tmp/mobileharness-signal-priorities-device-{build,install,app,launch}.log`。

## 2026-11-13 Decision 一来一回窗口

- 10 项 Decision 专项回归通过。回归从最终 ASR 入口检查实际分类请求，覆盖历史配对、批次中用户原文、当前状态字段、关联追问、候选顺序及对话正文中的换行和控制标记。Swift 原生 D3 制品冒烟测试通过，热调用 65.97 ms（`/tmp/mh-decision-history-focused-final.log`）。
- Mac 上用本地 D3 Edge Core AI 对照 28 条合成样例。英文版 18/28，误丢弃 0，误打断 5，漏打断 1，最长 51.89 ms。iPhone 并发播报时的端到端 100 ms 仍需实测。 [中英文对照](Decision-Model-Mac-Comparison.md#同一窗口的英文提示词对照)
- 四个 iOS Simulator scheme 构建通过。最终主应用增量重建通过，包内 `InputDecision.json` 与源码逐字节一致，资源和 WidgetKit 校验通过（`/tmp/mh-decision-history-ios-final.log`）。
- 首轮全量集成检查在更新过程命中旧中文标签断言、旧资源副本及两个 Writer 追问用例。最终 `./scripts/check.sh` 退出 0，1,147 项集成测试与 228 项 LiveRuntimeTests 通过。相机 Metal 用例只有启动记录（`/tmp/mh-decision-history-check-final.log`）。Writer 目标选择用例的 17 个场景也单独复跑通过（`/tmp/mh-decision-history-adjacent.log`）。

## 2026-11-13 任务请求、回报与运行时反馈命名

- 角色配置断言核对 Assistant 的完整接收与发送权限及 Writer 的一收一发。固定任务的进度和终态共用 `agent.task.response`，历史预览按消息类型解析，父子执行停止回归核对运行时终态及资源清理。
- SQLite 迁移回归以 20261112 契约名写入待发 Writer 终态，升级后验证正文、原消息关联及 outbox 领取。脚本模型回归验证 Writer 终态拒收后仅重投通知，以及多来源批次对固定任务回报保留可信来源。
- `./scripts/check.sh` 退出 0，1149 项集成测试和 228 项运行时测试通过。`./scripts/build-ios.sh` 退出 0，四个 iOS Simulator 目标和应用内 46 项 Agent 与 Skill 资源校验通过。`git diff --check` 通过。本轮未执行真实模型或真机验收。

### 真机覆盖安装

- Mobile Harness 0.1.0（2026111304）签名构建通过，校验 46 项 Agent 与 Skill 资源及 Live Activity。已覆盖安装至 Youwei’s iPhone 17 Pro（安装回执 6860），设备清单确认构建号，系统启动成功。覆盖安装保留应用数据。真实模型及真机交互未在本次安装中验收。

## 2026-11-13 Decision 动作定义与示例

- Mac 本地 D3 Edge 在 46 条合成输入上由 27 条正确增至 28 条。误打断由 8 降至 3，误丢弃由 1 降至 0，漏打断由 4 增至 6。新版最长 61.62 ms。 [对照与逐条标签](Decision-Model-Mac-Comparison.md#三种动作定义与对照示例)
- 四个 iOS Simulator scheme 构建和应用资源校验通过。`./scripts/check.sh` 退出 1，D3 超时后重试与云台最新目标两个用例在全量集成阶段失败，随后两项和提示词请求、打包断言共 11 项专项复跑通过。228 项 LiveRuntimeTests 通过，相机 Metal 用例记录通过。日志位于 `/tmp/mh-decision-examples-{ios,check,focused}.log`。
- 真机签名构建和严格签名校验通过，包内 `InputDecision.json` 与源码逐字节一致。iPhone 17 Pro 已覆盖安装并启动 `0.1.0 (2026111305)`，设备清单确认构建号，安装序号 6884。本次包含三种动作定义与四个英文对照例。证据见 `/tmp/mh-d3-prompt-device-{build.log,install.json,after.json,launch.json}`。

## 2026-11-14 Decision 防止误丢弃

- 真机应用数据目录可读。Decision 明细由 UI 根在内存中保留，已丢弃语音不写对话数据库，未能从设备文件回查用户反馈中的具体原句。
- M5 Mac 本地 D3 的 90 条合成样例及离线采纳规则回放中，误丢弃从 2 降至 0，误打断从 3 增至 5，漏打断从 11 降至 10。新版最长模型调用 51.84 ms。 [模型结果及逐条数据](Decision-Model-Mac-Comparison.md#保留明确指令和可能有效的转写)
- `./scripts/check.sh` 首轮集成阶段因现有 D3 超时重试夹具在并发下超出测试预算退出 1。扩大该夹具的测试期限后，最终 1,152 项集成测试及 11 项 Decision 专项通过。脚本的 228 项 LiveRuntimeTests 通过，相机 Metal 用例只有启动记录。四个 iOS 模拟器目标构建通过。日志位于 `/tmp/mh-d3-discard-{check,integration-final,focused-final,ios}.log`。
- 真机签名构建和严格签名校验通过，包内 `InputDecision.json` 与源码逐字节一致。iPhone 17 Pro 已覆盖安装并启动 `0.1.0 (2026111401)`，安装序号 6892。证据见 `/tmp/mh-d3-discard-device-{build.log,install.json,after.json,launch.json}`。真机交互和并发语音时延尚未验收。

## 2026-11-14 Decision 中英文打断近义词

- 124 条 Mac 本地模型探测及采纳回放对照中，接入版的误丢弃维持 0，误打断从 8 降为 7，漏打断从 21 降为 20。 [实验方法与逐项结果](Decision-Model-Mac-Comparison.md#中英文打断近义词)
- `./scripts/check.sh` 退出 0，1,152 项集成测试、228 项 LiveRuntimeTests 通过。相机 Metal 用例只有启动记录。四个 iOS 模拟器目标构建通过，应用包内提示词与源码逐字节一致。日志位于 `/tmp/mh-d3-synonyms-{check,ios}.log`。
- 真机签名及资源校验通过。iPhone 17 Pro 已覆盖安装并启动 `0.1.0 (2026111402)`，设备清单核对构建号，安装序号 6900。真机包内 `InputDecision.json` 与源码逐字节一致，含中英文打断近义词。证据见 `/tmp/mh-d3-synonyms-device-{build.log,install.json,after.json,launch.json}`。

## 2026-11-15 Decision 动作定义前置

- 本地 D3 和云端工具共用四段业务提示，按动作定义、当前对话最近一轮历史、同会话待发送用户文本、最新一句三选一的顺序渲染。历史每方最多 80 字，缓冲最多三条且每条最多 80 字。D3 读取原生数字选项，云端保留强制分类工具。
- 中英文顺序、上下文转义、旧轮投影、队列顺序、来源过滤、模型路由与采纳回归随 1,159 项 IntegrationTests 通过。全量检查在 AppWorkflow 阶段出现 Writer 声明注入缺失和网页截图用例失败，见 `/tmp/mh-history-buffer-check-final.log`。
- `./scripts/build-ios.sh` 四个模拟器目标均通过。两份 Decision 提示词资源与模拟器包内文件逐字节一致。真机部署由用户自行测试。
