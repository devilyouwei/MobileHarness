# Documentation and architecture change history

## 2026-10-15 — 总体第三部分与模块细节归位

- 按用户要求收敛 MobileHarness/README.md 第三部分：保留跨模块链路、数据流、注入接口、权限/所有权和完成/失败语义；局部算法、状态机、完整函数清单及参数引用所属目录 README。第一、二部分和第三部分章节入口保持不变。
- 在 Agents/Core/Chat、宿主 Behaviors、Gateway Resources、ModelKit Chat、UI Conversation 和 Settings 文档中补齐缺失细节；语音分段/声源、视觉调度、机械臂、模型资源、媒体和持久化已有完整契约时直接链接，避免再复制一份。角色处理、工作状态和资源交接内部图归位，总体保留并校正跨模块图。
- 对照源码修正四轮/十六原生调用上限、持久化热 Context、资源清理确认时限、语音发布者、宿主协议投影及照片旧索引/保留配置等过期说法。此前 system 来源图和 Task/Skill 生命周期图保持原样。
- 本轮仅调整文档。范围、完整性与链接检查见 [验证记录](../validation/Validation-History.md#2026-10-15--part-iii-detail-ownership-reconciliation)。

## 2026-10-15 — 代码 README 只维护现行技术契约

- 按用户要求整理 142 份受版本控制的目录 README，覆盖 MobileHarness、Tests、Macros、Config 和 scripts。保留当前职责、接口、算法、状态、生命周期、容量与失败契约，集中列出待实现项。Assistant 的 system 提示词来源图保留。
- 迁出的旧契约和演进原文归入 [README 历史摘录](Code-README-History.md)，测试、构建和设备证据归入 [README 验证摘录](../validation/Code-README-Validation-History.md)。重复原文合并列出来源，保留原日期、数值、失败和证据限制；更新维护规则与索引。
- 修正过期章节引用及自动重试、反馈期限、调用预算的矛盾说明。本轮只改文档，此前未提交的实现和测试修改保持原样；见 [检查记录](../validation/Validation-History.md#2026-10-15--code-readme-current-contract-audit)。

## 2026-10-15 — Task 完成与目标转移教学、紧凑 ReACT 观察

- BasicSkill21 以当前 activeTaskID 与匹配目标决定 finishTask/cancelTask；无 Task 的拍照/保存/查询直接完成回复。目标转移不明确时先问是否继续实际旧目标并保留 Task；明确替换不重复问，按需用 continueDecision 处理同一输入剩余请求。无 Task 的明确目标转移可主动释放无关近期 Skill，保留基础和仍需要的能力。Photography20 / HistoryQuery9 同步规则及条件示例。
- 共享 Chat 在模型正文中使用轮内调用序号、当前别名、真实状态和结构化 value；不再输出内部 callID 或把业务 JSON 二次编码为 result 字符串。拒绝明确未执行，失败/部分成功保留效果与全部叶子证据，去掉空报告字段；业务空值/null、业务引用、native 配对及完整内部日志保留，续轮分类不变。
- 新增/更新生产示例解析、同名调用、Action/Tool 混合、拒绝/失败/取消和日志隔离回归。相关 123 个函数 / 224 个场景通过；完整检查及 iOS 构建边界见[验证记录](../validation/Validation-History.md#2026-10-15--task-intent-teaching-and-compact-react-observations)。没有修改设备执行/Task 状态机协议或进行真实模型验收。

## 2026-10-15 — 多轮对话、Task 与 Skill 边界测试补强

- 盘点核心 40 个测试函数（含 1 个真实模型 opt-in），新增 21 个离线函数 / 43 个场景；补齐预加载接管与三种终态、计数暂停/最后一轮续期、容量精确边界/失败回滚、会话隔离及提交失败重试。
- 通过真实 Assistant 处理链的七轮目录到期和八次 Tool ReACT，验证回收只影响后续请求、历史证据保留、内部循环不重复扣数；本次未改生产实现。
- 按用户要求只执行相关专项：116 个函数 / 208 个展开场景全部通过。覆盖矩阵在 Tests/IntegrationTests/README.md，[验证记录](../validation/Validation-History.md#2026-10-15--taskskill-multiturn-boundary-test-audit) 区分合成检查与真实模型/设备验收。

## 2026-10-15 — Task 终态回收与无 Task Skill 五次闲置保留

- Task 只取得指定/实际使用的 Skill，终态回收持有项；无 Task 的加载和合法 Action/Tool 使用续期为五次完整用户决策，内部 ReACT 不扣数。移除按单输入立即释放的旧实现。
- 加入三项/24 KiB 非基础激活预算、受保护使用集合、确定性 LRU、4 KiB 发现目录和原子失败。新对话/重启清理，定向取消保留其他会话；当前目录与完整指令一起生效/回收。
- 当前 owning READMEs、Skill 教学/修订及 ADR0212 已同步；[验证记录](../validation/Validation-History.md#2026-10-15--task-owned-cleanup-and-five-decision-skill-retention) 区分通过的合成回归、设备目标编译、全量检查失败和真机验收缺口。

## 2026-10-15 — 按文档职责整理当前说明与历史证据

- 验证报告及语音验收指南归入 validation，变更、里程碑、旧说明与原始 Markdown 设计归入 history；原始 Word 设计源保持原路径与内容，原始测量继续由 measurements 保留。
- 精简重写文档索引、架构、路线图、概念和产品范围，移出混杂的旧实施叙述；当前说明不再复制默认值、迁移经过和历史构建结果。历史中保留独有上下文，清除 41 段完全重复叙述。
- 模型报告改为按各节日期解释，消除历史装配冒充当前默认及未经证据支持的崩溃归因；保留测试数字、设备观察与失败。同步引用和 Xcode 文档导航，不改变业务实现。

## 2026-10-15 — 完整需求完成后统一归档

- 新建 completed 集中归档六份原范围已完成的需求/实施记录：Action 文档与 Skills、Tasks/Skills 迁移、ModelKit Support 重组、ModelKit 解耦审计、SQLite 迁移和 Storage 接口分离。
- 归档以原定完整范围为单位，部分完成文档仍留 requirements；后续独立 bug 修复或 feature 扩展不阻止原需求归档，也不能将原范围缺项重新命名为扩展以提前归档。历史验证失败与独立验收状态保持真实。
- 恢复四项核心架构需求的整体状态及已完成子项说明，整份继续保留待办；更新分类规则、归档索引和全仓文档引用，不改变业务代码或原始设计源。

## 2026-10-15 — 未实现需求分类整理

- 新建 requirements/technical 和 requirements/product：核心架构剩余需求归技术类，相册与记忆归产品类；Resource 状态和摄影构图/运镜等交叉需求放在 requirements 根目录。各目录增加分类与维护索引。
- requirements 仅保留未实现范围。原架构计划第 4 项存储抽象已完成，转入 Storage 实施历史；已完成的 SQLite、Skills 和 ModelKit 计划保留为实施/决策记录，验收事项仍归验证文档。
- 原 Requirements.md 的当前产品说明改为 Product-Scope.md；更新 Roadmap、文档入口、相对链接和 Xcode 文档引用。保留原始 Technical_Design.docx，不改变业务代码或编译成员。

## 2026-10-15 — 用户相册与日记式记忆需求

- 记录“用户”板块内与“Agent 记录”并列的相册、记忆两个独立页面，均为待实施产品需求。
- 相册覆盖 Photography Tasks 的图片、视频等产物，区分长期作品与临时缓存；记忆按时间组织，周期性增量更新摘要、关键词、embedding 和原始对话索引。
- 明确记忆周期和粒度待细化，更新服务独立于页面生命周期；视频、embedding 和日记式记忆仍需补齐。更新 Requirements、Roadmap 和文档索引，本次仅修改需求文档。

## 2026-10-15 — Camera Skill loading and rejected-call feedback

- Teach current-catalog loading before standalone camera save/discard/close, including previews retained after capture-only decisions. No Task requirement is added; ignorePhoto remains the canonical discard alias and model photo examples use media_N.
- Return explicit pre-execution rejection evidence and catalog/Skill-control correction guidance for XML Actions and native Tools. No alias fallback, automatic loading or device replay is introduced.
- Synthetic regression and build limitations are recorded in [validation history](../validation/Validation-History.md#2026-10-15--camera-skill-availability-and-rejected-alias-correction).

## 2026-10-14 — 四项核心架构改进计划

- 记录 Storage 通用内存状态机制、错误分类与用户文案/开发日志分层、App 模块管理与桥接、存储抽象接口四项待实施计划，说明职责、实施衔接及验收范围。
- 明确 Storage 不拥有业务转换规则，用户点击即时反馈/页面跳转直接走 UI 或宿主能力，Agent 发起的 UI 控制保留 Action 路径；抽象存储不得掩盖持久化失败。
- 关联既有 Resource 当前状态存取和 SQLite 迁移计划，更新 Roadmap 和文档索引；校正 Roadmap 中已过时的 UI → StorageChat 依赖描述。本次仅变更计划文档。

## 2026-10-14 — Stable short references for model history reads

- Physical history confirms the model copied a listed conversation UUID suffix incorrectly, received notFound, then read the correct UUID successfully. The query backend did not lose the conversation; the historical failure remains real evidence.
- History.list now exposes an eight-hex ref only when its stable UUID prefix is unique across current/archives. History.read validates a typed short/full reference, resolves only exact unique metadata matches and rejects missing/ambiguous references. No guessed UUID correction, persistent alias table, file-schema change or UI change.
- HistoryQuery revision6 prefers exact returned refs and permits one fresh-list/corrected-read recovery after notFound. Canonical UUIDs remain available for collision disambiguation and other history operations. Validation is recorded in [validation history](../validation/Validation-History.md#2026-10-14--stable-short-history-reference-regression).

## 2026-10-14 — Function Catalog placement and direct detail contents

- Return the request's decision-snapshot Function Catalog to Tasks and Skills; retain actual messages/declarations under Prompts.
- Remove Parsed Output and Metadata disclosure wrapper rows, show their original contents directly in Action Execution/Generation Meta and delete the obsolete metadata expansion state. Native JSON export and request navigation retain their existing contracts.

## 2026-10-14 — English history detail headings and JSON sharing

- Use User Request / Assistant Response / Tasks and Skills / Prompts / Action Execution / Generation Meta headings. Keep actual Tool results and execution errors separate from explicitly labelled parse-only preview, consolidate Task identities/Skills and sent declarations, and retain collapsed generation metadata.
- Share loaded conversation, task or displayed request values as public.json with stable .json filenames. On-demand bounded native transfer encoding preserves raw request/response/evidence fields; delete the formatted diagnostic-text/report implementation. No history backend or storage format changes.

## 2026-10-14 — Hierarchical history separators and native preview

- Refine separators by hierarchy: conversation/task boundaries span both card edges; task-internal lines and icon-free source text start at the 52-point primary text column. The last source restores a full-width task boundary; expansion wording follows the task text column.
- Compile the actual UI page/state/presentation sources with synthetic history fixtures as an isolated native simulator preview. Capture collapsed and expanded screens; this is static layout evidence, not a successful full application/CoreAI build or real-model/device acceptance. Physical installation awaits the user's review.

## 2026-10-14 — History separator alignment

- User screenshot shows an extra first-row top line and separators that follow text indentation differently for icon/no-icon rows. Hide timeline Section outer boundaries and row top edges; retain shared bottom separators aligned explicitly to row-content edges with uniform horizontal insets for metadata, expansion and request cells.

## 2026-10-14 — Contiguous history layout correction

- User physical screenshots rejected the separate-card gaps and redundant task Section title. Replace per-item Sections with one contiguous timeline, retaining independent cells/native separators and increasing only internal request padding.
- Keep conversation/task icons on top-level items; omit icons from expanded task requests. Preserve orange ReACT text and move its badge after the bottom date/status. Single-destination navigation and immediate expansion are retained.

## 2026-10-14 — History task layout and single request navigation

- Conversation/task rows have distinct icons and task goals use blue. Task metadata and expanded original requests occupy separate native List cells/Sections with spacing and separators; expansion suppresses implicit cell-content animation.
- Replace multiple nested NavigationLinks inside one compression cell with plain request Buttons and one page-local navigationDestination. Active selection rejects duplicate taps; native dismissal clears the presentation flag and allows reopening while preserving expansion. No persistence/backend contract changes. Validation and remaining native acceptance are recorded in [validation history](../validation/Validation-History.md#2026-10-14--history-task-layout-and-single-request-navigation).

## 2026-10-14 — Isolated audio-detection communication startup

- Fix Settings audio detection failing before microphone startup with CommunicationError.unauthorized: restrict SpeechPerception communication to existing media.audio/sound.source rights, excluding the absent Assistant reply-activity dependency. Preserve full conversational configuration and native cleanup.
- Replace the broad-policy/test-only bridge in the diagnostic regression with the real single-Agent policy, bound Gateway consumer and production signal pump. Reproduce the original unauthorized assembly and verify mono/spatial observations without ASR/VAD/presentation calls.

## 2026-10-13 — Task历史原位压缩与新存储格式

✅ 新历史格式将请求开始时的决策快照与历史Task归属分开；启动请求、任务过程和关闭请求按稳定ID索引，终态压缩独立持久化。上下文和历史查询按请求顺序原位替换，UI可展开原始记录；同一输入中的多个Task分别归属。生产切换到新的Assistant上下文文件，旧数据不导入，移除旧Task状态升级、末尾汇总及已结束Task的整turn过滤。完整检查、设备SDK编译和资源校验通过；模拟器限制及原生验收边界见[验证记录](../validation/Validation-History.md#2026-10-13--indexed-task-history-v2-and-inline-compression)。

## 2026-10-13 — Immediate listening after reply

✅ Removed the 350 ms playback guard and its helper/tests. SpeechPerception retains policy and App retains physical capture ownership; listening restoration joins native playback/lease cleanup as soon as policy permits, with explicit error/cancellation handling. This supersedes the idle-tail portion of the earlier TTS optimization; PCM/segmentation/synthesizer changes remain. Nine focused regressions, 96 App workflow tests and the unsigned iOS device build pass; full-suite sound-source failures and the simulator dependency limitation are recorded in [validation](../validation/Validation-History.md#2026-10-13--immediate-listening-after-reply-without-an-acoustic-timer).

## 2026-10-13 — Streaming TTS latency

✅ Implemented: immediate initial Apple PCM with subsequent bounded coalescing, 20/60 first speech segments followed by 60/120, reusable fenced system synthesizer, and a root-owned replaceable 350 ms acoustic idle tail instead of per-segment blocking. Default voice/rate and bounded failure contracts remain. Focused regressions, opt-in Mac system synthesis and unsigned iOS device builds pass. Whole-suite failures/stall and the CoreAI simulator limitation are recorded in [validation](../validation/Validation-History.md#2026-10-13--streaming-apple-tts-latency-and-continuous-playback). Phone acoustic/latency acceptance remains pending.

## 2026-10-13 — 关闭云端 thinking 并修复阿里云标题生成

- 真实 qwen3.8-flash 标题请求复现：64 个输出 token 全部用于 reasoning，返回 incomplete/max_output_tokens，Memory 正确拒绝空标题。共享 OpenAIChatConfiguration 请求编码对已识别阿里云地址发送 reasoning.effort=none、enable_thinking=false；普通聊天和标题生成同时生效，保持原来的 64-token 标题预算和原始消息边界。
- OpenAI 支持关闭推理的规范 GPT-5.x/GPT-6 模型 ID 发送 reasoning.effort=none；旧非推理模型保留原参数，不添加阿里云字段。已知不能关闭 thinking 的 OpenAI 模型明确拒绝，不用低推理强度冒充关闭。未知别名/模型能力仍需单独验证。
- 保留 reasoning 响应解析、取消/资源清理、原生调用配对和标题失败契约。新增编码、未完成标题及 opt-in 真实标题回归；验证与部署范围见[验证历史](../validation/Validation-History.md#2026-10-13--cloud-thinking-off-and-qwen38-title-generation)。

## 2026-10-13 — 撤回连续 user 请求适配

- 按用户要求，撤回 OpenAI Responses 与 Gemma 提示词生成中的连续 user 合并，恢复原始消息边界和文本；删除合并专用回归，改为检查原始连续 user 与图片边界。
- 保留阿里云 Responses reasoning 兼容修复。使用已授权本地配置，经 OpenAIChat.chat() 直接发送 system/user/user/assistant/user/user，qwen3.5-35b-a3b 成功返回预期答案；这只证明该模型接受此请求，不推广为所有模型都支持连续 user。验证范围见[验证历史](../validation/Validation-History.md#2026-10-13--restore-original-user-message-boundaries)。

## 2026-10-13 — 阿里云 Responses reasoning 兼容

- 使用用户授权的本地阿里云配置，通过真实 OpenAIChat.chat() 复现 HTTP 200 后 unsupportedOutput：阿里云默认输出 reasoning 项及 response.reasoning_text.delta/done。实发六条历史消息已经合并为 system/user/assistant/user，未复现该请求的连续 user 编码错误。
- ChatEventDecoder 新增 reasoning 项及事件的格式验证与私有通道过滤；仅最终 output_text 进入回复和首 token 采样，保留原生调用的原始 output_index、配对、终态与有界失败契约。新增三个离线回归和显式 opt-in 真实接口测试；本地密钥未写入源码或证据。验证与部署范围见[验证历史](../validation/Validation-History.md#2026-10-13--aliyun-responses-reasoning-compatibility)。

## 2026-10-13 — 请求层合并连续 user 消息

历史阶段：该适配已由同日“撤回连续 user 请求适配”移除；以下保留当时的变更记录。

- OpenAI Responses 编码与 Gemma 本地提示词生成在模型边界合并连续 user 消息；相邻文本以两个换行分隔，图片保持原有文本/图片顺序。system、assistant、原生工具调用及结果保留边界，不自动补造 assistant 消息。
- 保留 ChatRequest.messages 和调用方聊天记录；原始消息数量、文本、图片和工具配对验证不变，云端插入的分隔符计入 64 KiB 文本上限。新增离线序列化和本地提示词回归；没有新增目录、模块或依赖。验证范围见[验证历史](../validation/Validation-History.md#2026-10-13--consecutive-user-request-adaptation)。

## 2026-10-13 — 平滑眼睛表情轮廓

- 修复笑眼等表情侧边控制点反向弯折，以及不同轮廓锚点在动画插值时产生的异常突出。EyeGeometry 统一为八段三次曲线，共用连接点与切线；笑眼、斜眼和闭眼变形同步调整切线，爱心使用对应的语义锚点。
- 保留原生 path/shadowPath 插值、动画时长、打断接续与完成回执。增加所有双眼表情组合及中途打断的几何回归；没有新增目录、模块或依赖。检查、预览和构建范围见[验证历史](../validation/Validation-History.md#2026-10-13--smooth-eye-contours-through-expression-transitions)。


## 2026-10-13 — 历史记录收敛

- 将“对话历史”改为“历史记录”，页面仅保留 Assistant 聊天记录与任务记录；任务包括 Assistant 的前台任务及已登记后台任务。
- 移除独立历史文件导入、导入标记、旧续轮字段及合成行、图片文本解析、旧 Mode 标签、三个 specialist 历史入口及投影。固定执行者只持久化事务/任务状态，Assistant 通过自身 context 事务保存聊天历史。
- 清理相应文档与旧回归，补充当前模型请求、任务归属、独立旧文件不参与加载及重启中断的验证。页面板块重新设计另行开展；构建与测试结果见验证记录。


## 2026-10-12 — Centered lamp-arm icon composition

- Recenter the selected first expression-refinement design as one phone/arm/base group, balancing opposing canvas margins while retaining the tilted phone, cyan expression and hidden rear magnetic mount. Preserve the earlier selected source and the new built-in ImageGen edit/prompt in output/icon-concepts.
- Refresh the opaque 1024×1024 lamp-arm variant and selected AppIcon.png through the unchanged selector; the root README already shares that selected image. Asset/link checks are recorded in [validation history](../validation/Validation-History.md#2026-10-12--centered-lamp-arm-icon-composition).

## 2026-10-12 — Selected lamp-arm app icon

- Select the first image from the latest expression-refinement turn: white lamp-like arm, tilted iPhone face with cyan open/winking eyes, rear magnetic joint hidden behind the phone and no screen halo. Preserve the full-resolution approved source and prior alternatives in output/icon-concepts.
- Package the approved image as opaque 1024×1024 AppIconVariants/lamp-arm.png. Extend the existing selector with lamp-arm and copy it into the universal AppIcon.png asset without changing asset declarations or runtime behavior.
- Point the root README logo at the selected AppIcon.png so documentation and app share one selected image; retain old icon sources and existing logo sizing/style. Checks and build limitations are recorded in [validation history](../validation/Validation-History.md#2026-10-12--selected-lamp-arm-app-icon).

## 2026-10-12 — 回复切换时录音暂停、长按打断与 GPU 光环

- 确认语句完成后停止原生麦克风，回复策略与播放／350 ms 尾音全部结束后重新采集；持续聆听授权和睁眼状态保留。采集启停串行、取消后加入清理，旧帧／错误按采集 epoch 隔离。
- 用户长按关闭立即停止播放、采集并屏蔽迟到呈现，明确关闭聆听授权。当前 Assistant 的模型取消与按实际 Agent incarnation／session 选择的已接纳 Action 取消并行加入，能打断等待播放的 round seal；不关闭共享 session 的其他 Agent／摄像资源。显式 agent.cancelled 终态保留原 input／round，取消不伪装成成功或普通错误。
- 空间 PCM 时间不连续／采样率变更使用独立类型与实际证据，64 包真实队列溢出仍显式失败。
- 光环用 UI 自有 Metal 单次绘制，增加彩色流动光场、移动亮点、侧边启动闪光和 850 ms 内收回的泛光。字幕用两个 Text 段与原生透明度插值；闭眼时暂停重复 Timeline 更新。
- 自动测试、原生目标编译、视觉预览与物理设备验收分别记录在 [验证历史](../validation/Validation-History.md#2026-10-12--reply-capture-interruption-and-gpu-halo)。未增加目录或第三方依赖。

## 2026-10-12 — Project banner and README review

- Place the approved 3:1 laboratory banner below the English italic slogan in the root README. Retain the source artwork and prompt in output; identify diverse robot coordination as the vision and NexArm as the current integration.
- Describe Assistant-owned conversation, bundled Skills and the single foreground Task. Correct Quick Start to use the half-second eye hold and default-off camera preview; document local Gemma hardware, image and native-Tool limits.
- Repair the module-design anchor, update Agent/Skill packaging wording and condense download recovery details into owning-document links. Preserve unrelated changes. Documentation verification is recorded in [validation history](../validation/Validation-History.md#2026-10-12--project-banner-and-readme-review).

## 2026-10-12 — 长按聆听、边缘光环与闭眼表情

- 首页双眼改为按住 0.5 秒切换持续聆听，松手保持开启；无障碍操作保留直接激活。提示、后台/中断恢复文字统一为按住。
- 开启后显示青蓝/紫粉/橙金流动边缘光环，使用多层柔光与细亮边；关闭时淡出，降低动态效果时使用静态光环。
- 未开启聆听时双眼呈柔和闭眼弧线，开启时平滑展开。Expression Action 新增 closed，有限演出仍等待进入/恢复的真实动画回执；关闭聆听时不将其他不可见表情报告为成功。
- App 在启动接纳时触发轻柔振动，在模型/权限准备完成后播放原创 420 ms 启动音；等待原生播放完成和 120 ms 余音间隔后才打开采集。PlatformKit 接收通用有界 PCM，不持有应用配乐/策略；失败、重叠和取消均明确处理。
- 回归、静态视觉核对、iPhone 编译及 Simulator 限制见 [验证记录](../validation/Validation-History.md#2026-10-12--press-and-hold-listening-feedback-and-closed-eyes)。Siri 精确长按时长及原声没有作为公开接口复制，本次采用明确的应用时长和相近风格原创提示音。

## 2026-10-12 — 首页任务与字幕布局优化

- 摄像头初始关闭；开启后 YOLO/FPS 头部保留，性能详情默认收起。
- 首页移除任务/Skill 卡片、Skill 数量和展开内容。前台任务改为用户 ASR 字幕上方的目标图标与单行 `任务：<goal>`，长目标省略并保留完整无障碍描述；无前台任务隐藏该行。
- 任务行与 ASR 字幕共享位置及固定间距，一起完成字幕上移动画，并为顶部摄像头控件预留空间。任务历史继续通过已有执行日志查看。
- 回归覆盖默认关闭状态、首次开启、紧凑/高屏幕字幕位置、任务与字幕间距、日志占位和无任务布局。构建及检查结果见 [验证记录](../validation/Validation-History.md#2026-10-12--home-task-and-asr-layout)。

## 2026-10-12 — Task context contraction

- Preserve full history while projecting ended Tasks as bounded historical summaries.
- Rebuild ReACT at Task boundaries and bind photos to producing Tasks; reject unscoped capture/cross-task operations. See [validation](../validation/Validation-History.md#2026-10-12--task-context-boundary-and-immutable-photo-ownership).

Purpose: retain dated documentation corrections and architecture changes without turning source-directory READMEs into change logs. For decisions that alter runtime contracts, follow the linked ADR; current behavior remains in the owning module README.

## 2026-10-11 — Assistant Skills and Task Modes

- Consolidate ordinary conversation into Assistant; replace specialist dialogue workers with fixed task coordinators while retaining camera/tracking, history/title and application transactions.
- Move Agent configuration into approved pure Resources assets; add dynamic Skill catalogs, one local foreground task and immutable per-request mode/Skill/function evidence. Controls reuse real Actions; send/publish semantics remain distinct.
- Separate Assistant conversations and task history; add bounded home task/Skill state without restoring Signal logs. Retire unused dialogue/voice grants and dependent subscriptions.
- Preserve canonical Actions and neutral module dependencies; cache immutable assets/configuration to protect short-lived perception inputs under parallel load. See [ADR0212](../adr/0212-assistant-skills-task-modes.md) and [migration record](../completed/Agents-Skills-Task-Modes-Plan.md).

## 2026-10-11 — Role-owned model prompts

- Move role/style and workflow prompts into four role-owned JSON template resources; remove Assistant-specific instructions from shared Worker and move delegation guidance out of the shared task schema source.
- Keep generic Function Token syntax and wait/Channel semantics in an independent AgentCore protocol resource. Role system templates supply speech/action ordering examples; native Tool definitions retain their separate request transport.
- Add strict bounded single-pass rendering and immutable role-resource discovery. Missing/malformed templates and variable mismatches fail explicitly. Preserve generation ownership, parsing and execution contracts; generated send examples respect each role's actual grants.
- Package and verify both role and protocol assets. Validation and Simulator limitations are recorded in [Validation history](../validation/Validation-History.md#2026-10-11--role-owned-prompt-templates-and-shared-function-token-guidance).

## 2026-10-09 — Execution log tabs and causal visualization

- Split the home execution sheet into Action(default), Signal, Task and runtime tabs, with Agent/status filters. Home and Action share internal-action visibility; caption/listening maintenance is hidden by default except failures. Scheduled Action execution remains separate from Tools and transport messages.
- Added neutral bounded Signal observations in Core and InputGateway: one row with subscriber branches, explicit publish/send/feedback modes, partial acceptance, rejection, suppression, loss and no-subscriber outcomes. High-frequency media/perception telemetry aggregates matching outcomes within one-second windows, without retaining media payloads or changing communication acknowledgments.
- Root presentation projects accepted public task reports into bounded parent/child timelines. Admission never completes a task; playback completion cannot replace waiting-user state. Details link related Signals, Actions and existing task-scoped model/ReACT/Tool history.
- Runtime displays lifecycle changes and infrastructure errors. Originating input IDs allow the same Signal/Action failure to be associated without hiding unrelated errors that share wording. No new directory/module/dependency or writable context was added.
- See [Validation-History](../validation/Validation-History.md) for automated/build evidence and physical/UI acceptance limits.

## 2026-10-09 — Camera-command delegation and concurrent admission

- Corrected task communication declarations: new delegation uses kind=request, authorized task kinds/targets are enumerated, and internal speech/telemetry grants do not expose unsupported model publication. Invalid XML/native communication is associated through the complete model catalog and receives bounded corrective feedback. Successful admission remains distinct from task completion; post-validation persistence/uncertain delivery failures remain terminal without automatic replay.
- ApplicationControl, Memory and Photographer serialize short fixed-state/context admission through a bounded FIFO gate instead of rejecting overlapping actor entry while a commit is suspended. Cancellation and stop release waiting callers; actual business queue bounds are unchanged.
- Production composition injects configured model labels into all four interactive histories. Existing phone contexts and historical records are preserved.
- Regression evidence and physical installation are recorded in [Validation-History](../validation/Validation-History.md). Synthetic camera/model tests do not establish physical runtime acceptance.

## 2026-10-09 - Shared Agent source hierarchy

- Consolidated reusable sources under Agents/Support/Core, Communication, Chat and Context. Core remains the independent Foundation-only AgentCore framework; business role schemas/policies/workflows stay in their role directories. Configuration loading joins Communication; model communication adaptation joins Chat.
- Relocated64 Swift files without changing their bytes, public declarations, schemas, grants, bounds or runtime behavior. Updated Package paths, exclusions, complete Xcode source groups, current documentation links and static import/path guards. No new target or dependency.
- See [ADR0189](../adr/0189-agent-support-hierarchy.md) and [validation](../validation/Validation-History.md); real-model/native-UI/device acceptance is unaffected.

## 2026-10-09 - Default entry and specialist task ownership

- Assistant now owns basic interaction and authorized task coordination. Photographer, Memory and ApplicationControl own their model capabilities, private durable histories and domain functions; deterministic UI workflows retain their original safety/confirmation semantics.
- Native/XML sends and fixed UI routing emit existing communication Actions/task Signals. Child execution results return to the actual executor; admission receipts, parent committed evidence and final task reports are separate boundaries. Removed the old function-delegation proxy/TaskLocal and Assistant-private Chat loop.
- Shared Support composition supplies one-round inference and bounded continuation; each role supplies preprocessing, schema, builder and grants. App owns stable interaction consumers independently of microphone and page lifetime. Task-scoped questions preserve speech-onset/text-admission and exact artifact identity.
- Explicit schema migration rejects partial/null/unsupported context. Cancellation joins owned work, including failed child cancellation delivery; queue expiry reports failure; restart interrupts without replay. No new directory, target or third-party dependency; Settings/History reuse the existing AppPresentationWorkflow consumer.
- Final repository checks passed (641 IntegrationTests/65 AppWorkflowTests plus remaining suites); unsigned iOS device build passed. Simulator remains blocked by external CoreAI. See [ADR0188](../adr/0188-specialist-task-ownership.md) and [Validation-History](../validation/Validation-History.md) for evidence and remaining real-model/native-UI/device acceptance.

## 2026-10-09 - Agent business source audit

- Implemented: standardized role actor/Processing layout, shared atomic Signal evidence commits, consolidated single-owner helpers and business Signal domain files, moved configuration loading into Support, and cleaned Xcode source references. Full repository checks and unsigned iOS device build passed; simulator remains blocked by external CoreAI. Preserve role policies and execution contracts; no new directory, target or dependency.

## 2026-10-09 - Agent shared component organization

- User-approved Support directory for shared Chat/context/storage adapters in the existing Agents target; Foundation-only AgentDecisionContext moves into AgentCore Runtime. Role policies remain in their existing directories, with no duplicate definitions, new target or dependency.

## 2026-10-09 — Agent composition and owned ReACT

- Migrated seven Agents to explicit preprocessing, structured context and context builders, retaining current business roles. Foundation-only Core owns bounded inboxes, batches, round/budget/task contracts; Agents owns atomic Storage adaptation and shared Chat capability/context drivers.
- Communication now leaves the Agent output stream as authorized Actions with distinct owner-directed admission receipts. Producer consumers bind actor/incarnation; task grants, parent/child reports, cancellation and runtime-stop cleanup preserve task ownership and causal identity.
- Assistant executes one model round per worker and queues ready continuation with user inputs. Exact native call/result pairs, independent task history and cumulative budgets survive interleaving. Deletion removes associated closed-task evidence atomically through the authoritative context.
- Recognition advances independently of reply source/task/decision. Listening follows actual playback with atomic utterance/playback admission and350ms tail cleanup. Current Photographer remains deterministic; photography LLM, active input focus and final role redistribution belong to phase two.
- No new directory, module or third-party dependency. Tests and build limits are recorded in [Validation-History](../validation/Validation-History.md); contract is [ADR0187](../adr/0187-agent-composition-and-react.md).

## 2026-10-09 — History image thumbnails

- History details show images sent to the model as thumbnails in the actual context section; tapping opens a read-only full-screen preview. Missing photos stay blank.
- Assistant writes structured imageReferences alongside exact request text/native calls; image bytes remain outside the JSON journal. Composition shares the existing photo store with camera and history. The history reader validates selected turn/reference ownership, reads by original producing input, admits at most four concurrent loads and propagates cancellation/failure.
- UI bounds retained image data to4MiB, thumbnail decoding to320 pixels and preview decoding to2048 pixels. Tests cover structured image metadata, deduplication, ownership, missing/corrupt references, failure, read bounds and cancellation. No new directory, module, dependency or storage path.
- Build, test and installation evidence is recorded in Validation-History; native visual acceptance remains separate.

## 2026-10-09 — Orange ReACT presentation

- Changed ReACT badge tint, list text/background and detail input-label accent to orange. Layout, row ordering, recorded values and interaction are unchanged.
- This is a color-only refinement; no new behavior tests were added. Repository/build/installation evidence is recorded in Validation-History.

## 2026-10-09 — Empty values in conversation history

- Removed legacy storage explanations from history lists, details and export. Missing model text, usage, first-token timing, finish reason and Tool outcomes are empty instead of synthetic placeholder text.
- Actual stored request content, model output, ReACT styling and recorded failures remain available. Persistence is unchanged.
- Removed the obsolete evidenceNote presentation field and retained a UI-only metadata-availability flag. Regression and build/install evidence is recorded in Validation-History.

## 2026-10-08 — Conversation history per model request

- Reordered details to current input, model text/native Tool Calls, generation evidence including first text-token arrival, actual context, then actual Tools. Removed inline raw sharing and the detail continuation section; retained one upper-right export.
- Flattened model invocations into peer list items, with ReACT badge, purple text/background and actual fresh execution observations as input. Details/export retain both model-round and owning-input identities and distinguish model completion from owner/execution errors.
- Added optional nested modelRequests evidence under the original input, preserving existing runtime/context ownership and current schema. Attachment bytes remain excluded.
- Final full checks and unsigned device-target compilation passed; Simulator remains blocked by the external CoreAI module. See [validation evidence](../validation/Validation-History.md#2026-10-08--per-request-conversation-history); native UI/live-provider/physical acceptance remains pending.

## 2026-10-08 — Signal classification documentation

- Expanded the overall Signal contract with origin/payload comparison, typed user-click intent routes and current external/internal domain inputs. Signal uses composition rather than inheritance; host/native inputs remain External even within the App process.
- Clarified camera activity production versus delivered Runtime feedback, missing video/binary payloads and current working generation-round feedback. No runtime code changed.
- Verified definitions, domain adapters, receiving Agent configurations, camera event producer and Gateway feedback entry points. Documentation formatting and relative links checked; builds and physical acceptance are outside this documentation-only change.

## 2026-10-08 — Assistant photo Action and image observation (ADR0184)

- Assistant exposes Camera.Capture.takePhoto on Camera Channel, registered observation. It directly invokes the camera host, without Photographer delegation, to validate ActionResult plus optional native ToolResult through the existing sealed-round loop.
- AppleCamera adds bounded joined JPEG capture; CameraCoordinator scopes capture/save/presentation to the originating invocation. Photos persist in a bounded owner-checked Storage store. The UI fades the complete image, shrinks it to the lower-right thumbnail and supports inspection; success waits for animation completion. Native shutter audio remains platform-owned.
- ChatMessage supports bounded user-role image attachments. Cloud serialization emits text/image_url parts; current provider capability is explicit and Gemma rejects image chat. Assistant resolves only successful owned photo results and attaches bytes to its next request; history retains attachment metadata and omits bytes.
- Synthetic Gateway/mixed-route, capture/read/provider failure, owned persistent storage, exact image JSON and request transcript regressions passed. See [ADR0184](../adr/0184-assistant-photo-observation.md) and [validation history](../validation/Validation-History.md#2026-10-08--assistant-photo-observation-loop).

## 2026-10-08 — Registered Action/Tool generation rounds (ADR0183)

- Split text/XML Action dispatch from native Tool execution. Assistant text, captions and reply-turn start use Actions; native Tools bypass Channel/wait and run under a four-worker/sixteen-call input bound. Removed scheduled native projection and reject scheduled native bindings.
- Host registration explicitly selects recordOnly/observation. Every initializer defaults recordOnly; value/void/error transport does not opt in to continuation. Both result types retain call/round correlation and join a full-round barrier before ordered merge, history evidence and another model request.
- Added typed round sealing, causal feedback validation, bounded terminal delivery, cancellation/join ownership and execution-versus-delivery failure separation. Existing deterministic Agents retain native presentation routes. No new module, directory or dependency.
- See [ADR0183](../adr/0183-generation-round-observations.md) for ownership, limits, flow diagram and [validation history](../validation/Validation-History.md#2026-10-08--registered-actiontool-generation-rounds) for automated and device-target evidence.

## 2026-10-08 — Lower finalized user caption

- Lowered only the finalized user-caption center by24 pt, including the compact-height minimum (60→84 pt). Listening/reply positions and animation remain unchanged.
- Full checks and signed generic iOS build2026100804 passed. Paired-phone installation is pending reconnection; see validation history.

## 2026-10-08 — Explicit camera targets and companion presentation

- Camera.Capture.flip now requires facing=front/back across Assistant native declarations, Photographer intents, shared function validation and typed native capability. Healthy same-facing requests do not restart capture; manual switching resolves the opposite target before admission. Removed obsolete direct coordinator toggle/switch entry points.
- ASR emits its final bounded caption before sealing it. User text moves above the eyes and remains beside the streaming reply until the next accepted turn; stopping voice retains displayed text. Cyan user and lavender assistant captions have distinct accessibility labels, with reduced-motion support and existing freshness fences.
- Gaze displacement increases to horizontal14%/vertical9% of face width. Love morphs both stable eye shapes into pink hearts using matching cubic segments and existing animation-completion acknowledgment.
- Tests cover target/argument validation, delegated target preservation, final-caption ordering, caption retention/reset and manual facing selection. Validation and acceptance limits are recorded in [validation history](../validation/Validation-History.md#2026-10-08--camera-target-and-companion-presentation-refinements).

## 2026-10-08 — Prefer default Action Channels in model prompts

- CapabilityContextBuilder explicitly prefers bare Action tags on their declared default Channels. Channel scopes are reserved for intentional routing overrides; concurrent work on different defaults needs no scopes or wait groups.
- Assistant adds a concurrent expression/dance example and discourages duplicate Actions emitted only to demonstrate routing. Parser support and scheduling semantics remain unchanged.
- Prompt regression checks the guidance and verifies two bare Actions route to Display/Robot without scheduling boundaries. Full checks passed (596 integration /51 workflow tests); simulator build is blocked by external CoreAI. Live-model instruction following remains unverified. See [validation history](../validation/Validation-History.md#2026-10-08--default-channel-prompt-guidance).

## 2026-10-08 — ApplicationControl business service (ADR0182)

- Replaced the root ResourceManagement actor/configuration/identity with directory-owned ApplicationControl; no compatibility alias remains.
- Grouped fixed function grants and pure resource-result policy in co-located helpers. Shared transaction exclusion, runtime-result correlation and bounded actor state remain together.
- Renamed App transport and public transport errors; updated registration, source/session guards, package resources, Xcode navigation and regression fixtures. Terminal control notifications migrate with their consumer.
- Photographer and Memory retain their domains. Native Actions algorithms, Signal schemas, cancellation/join behavior and error propagation remain unchanged. Generic specialist delegation is still pending.
- Full repository checks passed (596 integration /51 workflow tests). Unsigned device clean build and seven-config verification passed. Simulator remains blocked by external CoreAI; native UI/live-model/physical acceptance remains pending. See [ADR0182](../adr/0182-application-control-service-organization.md).

## 2026-10-08 — Photographer camera control (ADR0181)

- Move open/close/flip/retry decisions and returning results from ResourceManagement into PhotographerCameraWorkflow. Root Photographer outlives preview and explicitly attaches one vision scope.
- Manual camera operations and Assistant native calls share Photographer policy and Camera.Capture functions; bound Gateway delegation preserves source incarnation, scope and causal metadata. Complete nested failure reports return to the original caller.
- One root stream consumer owns independent bounded camera/tracking dispatch, cancellation acknowledgment and joined cleanup. Existing native permissions, leases, motor algorithms and capture safety remain unchanged. Final checks passed (596 integration/51 workflow tests), unsigned device build and seven-config packaging passed; Simulator remains blocked by CoreAI.

## 2026-10-08 — Memory and Photographer business service organization

- Renamed ConversationMemory directory, actor, configuration and live identity to Memory; retained history.intent/1 payloads and History function paths, without a legacy runtime alias.
- Extracted MemoryHistoryWorkflow and PhotographerTrackingPolicy; actor entry points use consistent registration/lifecycle/input/output sections. Existing title computation stays in Memory.
- Updated host identity fences, packaging, fixtures and current contracts. Added role naming checks and canonical identity/output overflow isolation tests. Full checks (591 integration / 51 workflow tests), unsigned device build and seven-config packaging passed; Simulator remains blocked by external CoreAI.
- Photographer retains its full photography/video/movement/interaction remit; richer memory and shooting capabilities remain explicitly unimplemented. See ADR0180.

## 2026-10-08 — Clarify Agent business roles

- Preserve Photographer naming and describe its full photography/video/movement/shoot-time interaction remit; distinguish implemented pose tracking from pending shooting capabilities.
- Withdraw the proposed PoseTracking rename. ApplicationControl remains a proposed application-operation role, not a universal domain router or only a screen-operation substitute.
- Clarify ConversationMemory's history/title implementation and pending semantic/long-term memory policy; persistence belongs to Storage and active-turn reasoning to Assistant. No actor, identity, directory or runtime behavior changed.

## 2026-10-07 — Agent-selected history archive and title

- Added typed startNew/summarize intents and fixed ConversationMemory permissions; archive/title effects now cross both Gateways through protocol-neutral History functions.
- Moved title computation to ConversationMemory; preserved title limits, commit-before-inference, raw-history retention and retry error persistence.
- Removed journal/inference callbacks from the feature facade. Added bounded terminal transport and read-only feedback-policy metadata; registration governs failure follow-up.
- Moved durability/model tests to the real Gateway integration path; added empty/missing/current archive and failure-presentation regressions. Validation pending.

## 2026-10-07 — Typed Assistant host control

- Replaced voice lifecycle cancellation strings with assistant.control/1 domain Signals through InputGateway.
- Removed Assistant runtime.event grants and event echo behavior; preserved session-scoped, full/paused cancellation and joined cleanup.
- Added schema, provenance, freshness, session-isolation and active-generation cancellation regression coverage. Final check.sh and unsigned iOS device build passed; all191 Mermaid diagrams parse. Simulator builds remain blocked by external CoreAIShared/CoreAI. See ADR0164 for evidence and remaining work.

## 2026-10-07 — Consolidated design consistency audit

- Reconciled business target versus current host routes, App external-input adaptation, protocol-neutral function terminology and catalog limits with implementation.
- Distinguished source names from Signal origin, execution completion from feedback admission, ActivityEvent transport from local camera records, and bounded failure scopes.
- Documented owned cancellation-independent cleanup, native versus local text model support, and pending resource-state context capabilities. Corrected native scheduling wording in the shared parser README.
- Runtime behavior and contracts are unchanged; checks cover document accuracy, links, diagrams and formatting.

## 2026-10-07 — Consolidated technical design

- Consolidated the active Agent-driven design into MobileHarness/README.md as the single overall technical design document.
- Integrated ownership, Signal semantics, six interaction scenarios, shared callable/protocol execution, typed history intent and feedback causality into responsibility-based sections; removed outdated migration summaries.
- Redirected links to the consolidated design and removed the redundant Agent-Driven-App.md file. Runtime code and historical evidence remain unchanged.

## 2026-10-07 — Current callable architecture documentation

- Reconciled public architecture, concepts, technical module mapping, roadmap/index and Resource-State-Plan with FunctionContracts, Gateway-owned ExecutionRuntime/CallRuntime and the retired Tools directory.
- Linked the two protocol-routing diagrams; clarified independent protocol availability, Agent exposure, native execution policy and feedback policy.
- Corrected execution-record wording for direct versus scheduled native calls. Preserved historical ADR/validation entries and the original Word design source.

## 2026-09-27 — Module documentation audit

- AgentCore: removed the InternalSignalBus description; Communication now documents contracts and policy while Agents own pending inboxes.
- Agents: replaced generic directory sketches with current roles and removed stale expression and migration examples.
- App: consolidated repeated presentation updates and corrected skeleton execution from Action to completion-only Tool.
- Gateway: removed model-processing ownership and distinguished returning Tools from completion-only Tools.
- ActionRuntime and ToolRuntime: clarified execution ownership versus Gateway admission/scheduling, and clarified that skeleton coalescing belongs to VisionPerception.
- Actions: removed obsolete emoji/expression and Photographer Action claims; skeleton presentation belongs to Tools/UI.
- ModelKit: removed old Gateway ASR/VAD ownership, YOLOv8 default and Photographer inference descriptions.
- PlatformKit: removed Gateway-to-inference edges and added audio spectrum telemetry ownership.
- Experience: replaced obsolete orb/emoji and Action-delivered skeleton descriptions; `VoiceOrb.swift` remains a filename, not the current visual design.
- Resources: distinguished active models, diagnostics and comparison-only profiles and removed obsolete artifact-layout wording.

## 2026-09-28 — Documentation ownership

The internal source/target map is now part of [MobileHarness/README.md's Project Structure](../../MobileHarness/README.md#source-structure-and-compilation-map). The unimplemented Photographer concept moved to [Photographer-Proposal.md](../requirements/Photographer-Proposal.md). [Architecture.md](../Architecture.md) now explains the product architecture externally, while source-directory READMEs own current module contracts. Dated UI/build observations moved to [Validation-History.md](../validation/Validation-History.md).

The full `docs/` review classified public architecture, roadmap, proposals, validation records, ADR history, original design sources and license notices. Historical technical designs and superseded ADRs now point to later decisions instead of presenting old models, UI, transport or Agent configuration as current. The original Word source and license texts remain unchanged.

## 2026-09-28 — Structured wait documentation audit

Corrected current parser, Agent output and Gateway diagrams to carry typed wait boundaries end to end. Clarified task-local FIFO versus process-wide Channel-name capacity and module exclusion. Updated the future ownership proposal to JSON v4 and a separate resource registry, since task lanes are no longer global. The historical technical baseline and ADR 0015 now explicitly link the superseding scheduling contract; the original Word source remains unchanged. Current acceptance work includes real-model and device validation of nested waits.

## 2026-09-28 — Persistent conversation history

Replaced the standalone raw-output diagnostic with current/past conversation browsing of real Assistant traffic. Storage now retains exact inputs, requests, received fragments and failure state; current context uses ten completed rounds and survives voice sessions/restart. Explicit New Conversation archives atomically, then generates a retryable title. Original historical data that was never saved cannot be reconstructed. See ADR 0060.

## Agent JSON v5 — 2026-09-28

Replaced redundant flat Agent declarations with version/id and Channel-grouped callable Actions. Internal speech, captions, transcript, gaze and overlay behavior now uses code-owned permissions with no model aliases. Tools retain a standard OpenAI function envelope. Shared generation accepts an Agent-owned text mapping, preserving speech/wait order and history previews. See ADR 0061.

## 2026-09-29 — App/UI ownership audit

Aligned source names with current ownership: ApplicationRuntime, VoiceSessionCoordinator, VisionSession, CameraConversationSurface, CompanionEyes, SpeechDiagnosticState and ChatValidationView. App/Adapters owns the current-chat binding wrapper; App/Workflows owns Debug chat diagnostic execution. Removed duplicate retained assembly values, the one-method AgentBootstrap wrapper, unused imports/errors and the obsolete legacy configuration writer while preserving migration reads and verified deletion.

Fixed the MOSS editor's stale task comparison, which resolved to SwiftUI's task modifier and always disabled editing. Restored the camera toggle's existing accessibility identifier. Module READMEs now describe the actual toolbar placement, state/workflow ownership, selected chat binding, model residency and editable credential scope; earlier historical names in this log and ADRs remain dated evidence. See [ADR 0064](../adr/0064-app-ui-boundaries.md).

## 2026-10-02 — Runtime boundaries and documentation ownership

- Independent ActionRuntime/ToolRuntime targets separate execution contracts from concrete behaviors; Gateway owns startup permission coverage and BehaviorAssembly constructs registries.
- Shared audio values compile under Types/Audio. Six feature workflow targets and injected provider/title/preview operations narrow host dependencies; lifecycle owners receive role-specific services and Agent factories.
- MobileHarness/README.md documents current architecture, module roles and complete cross-module technical flows. Eleven first-level module READMEs describe current ownership/contracts without accumulated update or acceptance records.
- The project README is a product/setup entry point. docs/README.md categorizes requirements, concepts, public architecture, plans, evidence, decisions, history and notices. Requirements.md and Concepts.md summarize current goals and terminology; Architecture.md and Roadmap.md no longer contain accumulated historical implementation notes.
- Earlier roadmap snapshots are preserved in Milestone-History.md; accumulated entry-page notes are preserved in Documentation-History.md. Original Word/Markdown sources, ADR bodies, validation data and license notices are retained.

Build, test and installation observations are recorded in [Validation-History](../validation/Validation-History.md).

## 2026-10-07 — Resource command Agent

Added typed resource commands, deterministic root ResourceManagement, pure System.ModelResources functions and bounded32-request transport. SDK adaptation reuses the process-wide manager; returning feedback and host retirement isolate invocation failures. Download success represents admission. No new directory, target, model instance or Assistant mutation exposure.

## Speech binding stage (2026-10-07)

✅ ADR0167 adds Agent-routed speech binding, strict booleans, configuration overlap rejection and invocation-local feedback. Preference application failures propagate after durable commit; cache invalidation allows explicit restore/retry. Native unchanged-preference suppression and lifecycle barriers are preserved.

## Resource preferences stage (2026-10-07)

✅ ADR0168 adds protocol-neutral durable preferences, legacy migration, installed-prerequisite validation and revision-checked source writes. ResourceManagement selects a bounded two-call sequence; Settings becomes an injected view facade. Failed preference application preserves durable commit and disables implicit effect retries during UI rollback/polling.

## Resource inventory stage (2026-10-07)

✅ ADR0169 adds bounded neutral resource inventory, shared installed prerequisites and typed refreshResources. Native adapter supplies facts only; Actions supplies group data; Settings no longer uses ModelResourcePolicy. Existing progress/failure text and request-generation fencing are retained.

✅ ADR0169 validation: full repository checks and unsigned iOS device build pass; large inventory return/overflow recovery is covered. Simulator build remains blocked by external CoreAI. Dated scope and remaining physical acceptance are recorded in Validation-History.md.

✅ ADR0170 adds generation-bearing refreshPresentation, shared inventory read composition and two pure UI functions. Agent owns failure follow-up; root transport retains primary/secondary errors and UI rejects stale revisions. No new directory, target, dependency or model-callable permission.

ADR0170 validation: resource regressions/workflows, boundaries and unsigned device build pass. Final full suite still has an intermittent BLE readiness/timeout failure; simulator dependency and physical acceptance remain outstanding. See Validation-History.md for revision-scoped evidence.

## Resource observations stage (2026-10-07)

✅ ADR0171 adds the root-owned foreground resource sampler and typed model.resource.state/1 Signal. ResourceManagement selects the existing presentation functions for changed/failed facts. The page refresh loop is removed; accepted snapshots release existing UI admission bookkeeping, and recovery clears only refresh-owned errors. No foundational SDK, Action execution algorithm, directory or model grant changes.

Validation and outstanding native/shared-state acceptance are recorded in Validation-History.md.

## Resource command failure stage (2026-10-07)

✅ ADR0172 adds Agent-selected operation-error presentation after failed download/cancel/remove results. The canonical function validates bounded arguments and awaits a required root-session endpoint. Successful presentation avoids duplicate local projection; missing/failed presentation retains native and secondary causes. Errors now expose readable retained descriptions. Native command algorithms, two-call bounds, cancellation ordering and foundational dependencies are unchanged. Preference notices and unavailable-Gateway host presentation remain staged.

Validation is recorded in Validation-History.md.

## Resource preference failure stage (2026-10-07)

✅ ADR0173 introduces exact producer failure codes, Agent-selected preference notice/error presentation and a shared terminal-failure identity set. Per-request transport allows three calls only for preference restore/save; other limits stay two. Preference/configuration exclusion remains held through error presentation. Confirmed visible flags roll back without overwriting accepted notices/errors or retrying binding; durable commits survive later binding/presentation failures. Native algorithms and protocol-neutral Actions remain intact. Host fallback/provider/shared-state and native acceptance remain outstanding.

Validation is recorded in Validation-History.md.

✅ ADR0174: recoverable resource admission/dispatch failures use a typed host Signal and one Agent-selected registered error function after original worker cleanup. No native retry or recursive presentation; startup/closed/capacity/in-flight diagnostic failures retain explicit infrastructure fallback. ❌ Provider settings, BLE/navigation Agent routes, shared context, bounded model continuation and native acceptance remain subsequent work.

ADR0174 validation: final full checks (565 integration /47 workflow), unsigned iOS device build and seven packaged Agent configurations passed. Required simulator script remains blocked by CoreAI; no install/native acceptance. See Validation-History.md.

✅ ADR0175: Settings provider model discovery now uses opaque provider.discovery intents, ResourceManagement and System.Provider.discoverModels with session-bound one-use private staging. Query results/errors are bounded and credential-free. ❌ Provider restore/save/rollback, lifecycle switching and registered provider UI effects remain a later migration; real provider/Keychain/native acceptance remains separate.

ADR0175 final verification: full574 integration/47 workflow tests, unsigned iOS device build, seven packaged configurations,205 Mermaid diagrams and303-file local link audit passed. Intermediate12-test/41-issue BLE failure and per-test passes are preserved in Validation-History.md; simulator remains blocked by CoreAI. No installation or real provider call.

✅ ADR0176: provider restore/save now uses opaque provider.settings/1 intents and registered Provider functions. Actions owns business schema/store/migration and complete apply/rollback; App only stages/adapts and supplies native SDK, lifecycle and credential primitives. ❌ Registered provider UI effects, SDK model-family eligibility migration, model grants/shared context and native acceptance remain subsequent work.

## Agent-driven completion batch (2026-10-08)

✅ ADR0177–0179 complete the existing-route migration: provider discovery policy moves to Actions; provider forms become passive and success/error projection uses registered functions; cloud native results continue under bounded correlated reasoning; device/navigation/camera human intents enter Agents and share canonical functions with model grants; current environment and resource/provider/device facts are queryable; UI no longer imports StorageChat. Manual motor workers retain their native arrival/tolerance/timeout behavior and report independent terminal failures through ActionResult. Assistant also has explicit model download/cancel grants.

New photo/system pickers, generic progress/request-reply, provider-changing session handoff, the separate resource-state-store plan and remote/durable transport remain product extensions. Automated tests/builds do not establish live-provider, Keychain, camera/BLE gesture or hardware acceptance. Evidence is recorded in Validation-History.md.

## 2026-10-08 — Photo overlay touch and voice recovery

Thumbnail inspection uses a compact Button; the full fade/shrink layer passes touches through. ReAct keeps recognition admission closed, including stale perception presentation. Full reply/playback completion restores listening explicitly. Native output workers are scoped per input; a failed reply cancels/joins its work and retains the Assistant subscriber for retry. Regression tests cover cancelled worker joins, retry Tools and intermediate round seals. Native touch/model acceptance remains pending.

## 2026-10-08 — Photo save and ignore

Added current-photo save/ignore Actions and Photographer intents shared by UI and dialogue, actual receipt return and observation-based confirmation. Add-only native Photos import waits for OS completion and prevents duplicate saves while displayed. Thumbnail/fullscreen controls provide save and ignore without intercepting voice controls. Scheduled Actions now carry validated invocation-scoped delegation authority like Tools. See ADR0185 for ownership, cancellation and acceptance limits.

## 2026-10-08 — Independent native Tool and text Action consumers

Assistant now demultiplexes model protocol fields into bounded text/Action and native Tool workers. App output transport has independent consumers: four active Tools cannot block Action/wait admission, and Action preparation/admission cannot block native calls. Both branches close and join before the existing full-round result merge and downstream model continuation. Parser/dispatch failure cancels and joins siblings even while model output is open; cancellation, bounded rejection and failed-input recovery remain explicit. Shared device resources/deadlines are unchanged; generic Agent request/reply remains separate. No new directory, module or dependency. See ADR0183 and Validation-History for actual verification limits.

## 2026-10-08 — Camera lens-switch latency

Healthy front/back switching retains the capture session/output graph and resource lease instead of full teardown/reacquisition. Old perception is fenced immediately and replaced by a bounded root-owned worker after joined cleanup; native command acknowledgment no longer waits for that cleanup. Off/background/model maintenance still join retirement, and native failure is explicit. See [ADR0186](../adr/0186-camera-lens-switch-lifetime.md); physical latency acceptance remains pending.

✅ Phase two specialist ownership implementation: [ADR0188](../adr/0188-specialist-task-ownership.md). Implemented; real-model/native-UI/physical-device acceptance pending.


## 2026-10-09 — Per-Agent conversation history navigation

History now opens a four-Agent picker, followed by each owner’s current/past conversation lists and existing detailed request/output/tool/usage/image views. App reads specialist archives from their live context repositories without starting a model or copying journals. Assistant mutation intents remain unchanged; specialist records are read-only. Stream-processing context without chat records is excluded. Automated and build evidence is recorded separately in Validation-History.

### 2026-10-09 — Assistant listening authority and one-way publication

- Assistant exclusively owns user consent/reply holds through fixed internal Speech.Listening.update. Child Agents report task state; App executes native capture/playback barriers and SpeechPerception executes admission.
- External inputs and perception observations publish one-way without recipient acknowledgments. send retains directed admission receipts; Gateway owns bounded fan-out/diagnostics/shutdown.
- Queue/ASR/VAD errors report through agent.error then reset the damaged utterance and continue. UI result loss/camera cancellation waits are bounded; never replay effects or infer device stop.
- Documentation and contracts: [ADR0190](../adr/0190-assistant-listening-and-one-way-publication.md). Real-device acoustics/native UI remain separate acceptance work.


## 2026-10-09 — SpeechPerception listening authority

Moved session listening consent and deterministic gate/recovery policy from Assistant into resident SpeechPerception. Four interactive Chat workers publish bounded revisioned reply occupancy, retaining actual task identities; generic streaming busy is excluded. SpeechPerception gates final ASR before publication and emits its own registered listening Action. App keeps native startup, capture epochs, confirmed-utterance/playback/tail barriers and revision-fenced native termination reports; Assistant listening Action/state and App orphan timer were removed. No new directory, module or dependency. Physical acceptance remains separate from automated validation; see Validation-History.

## 2026-10-09 — Assistant mechanical-arm Action ownership

The 11 unchanged Robot gesture/motor Action declarations now belong exclusively to Assistant; duplicate model permissions were removed from Photographer and ApplicationControl. Capability summaries keep ordinary arm interaction at the main Agent. App grants Assistant the shared motor writer and joined tracking takeover, while retaining fixed settings operations and internal photographic tracking. Role/prompt, actual executor/result routing and Bluetooth recovery fixtures cover the new ownership; no directory, dependency or native motion algorithm was added. Validation is recorded separately in Validation-History.

## 2026-10-09 — Shared mechanical-arm Action registration correction

Restored ApplicationControl Robot registrations for Settings command tests alongside Assistant basic interaction. Action-to-Agent registration is many-to-many; responsibility and required execution semantics determine each role’s Action/Tool permissions. Shared functions execute directly under the actual requesting Agent, without forced delegation for reuse. Photographer remains camera-only for model Actions. This supersedes the exclusive-registration policy in the preceding entry; resource exclusion and native motion implementations are unchanged.

## 2026-10-09 — Photographer Camera Actions and startup lifecycle races

Device context evidence showed camera open followed by three repeated back-lens calls exhausting the four-request budget, plus plain photo questions incorrectly completed without progress. Photographer now exposes all seven camera operations as scheduled Actions, with canonical structured preparation receipts and explicit active-task/photo-question reporting instructions. Same-round camera preparation/capture executes in order and joins feedback. Interactive scene changes await child registration through the root runtime, preventing early unknownAgent lookups. Fixed UI single-command Tool permissions, native safety and four-request budgets remain unchanged. Live-model/device acceptance remains separate from automated evidence.

## 2026-10-09 — Frontend and Agent backend separation

Local navigation now updates UI state synchronously; page visibility, system-settings opening and native stop fencing run immediately outside the business command queue. Typed camera/history/provider/resource/device data requests publish directly to their owning Agent subscriptions. Removed Assistant typed-UI subscriptions, relay hooks and fixed task-construction path; conversational delegation and scoped task inputs remain. Callable UI functions are retained, including scheduled openPage, sharing the local navigation presentation method with actual-producer/task authorization. Existing stored tasks are preserved; no directory or dependency was added.


## 2026-10-10 — Home execution log simplification

Home history now contains Action / Task / Agent. Removed Signal rows, passive UI storage, branch expansion and related Signal navigation. Root presentation observes only independently bounded task protocol snapshots, so ordinary audio/recognition/environment traffic never invalidates home log state or evicts task traces. Task admission/completion, related Action/history navigation, Agent lifecycle/errors and scheduler-driven popup remain. General Gateway Signal diagnostics remain outside the home UI. No directory, dependency or device-data change. Build/test evidence and native performance limits are recorded in Validation-History.


## 2026-10-10 — Provider-interface first-text timing

Conversation request TTFT now uses provider-side sampling: OpenAI HTTP invocation to the first nonempty decoded text delta, before stream buffering/Agent consumption. Optional per-request ChatTiming retains monotonic elapsed time and timestamps; Gemma uses native generation invocation. Context/history stores exact evidence rather than consumer arrival, and the old timing writer is removed. Details/export expose actual model request start and interface latency; unavailable provider timing remains absent. ASR, TTS, persistence and UI rendering are excluded. Streaming persistence behavior is unchanged; no live API request or dependency/directory change. Validation and physical latency limits are recorded separately.


## 2026-10-10 — Recognition subtitle rollover

Fixed new ASR previews inheriting the previous finalized upper-slot flag and reply text. VoiceSessionCoordinator now uses the shared accepted-update projection to reset both captions and transcriptFinalized when recognition identity advances. Same-turn partials retain the lower slot until finishTranscript; late/duplicate/closed updates cannot clear newer state. Agent task and playback ownership remain unchanged; no recognition/model or animation delay is added. Native layout and real ASR acceptance remain separate from regressions/build evidence.


## 2026-10-10 — Responses transport and Assistant Action-only calls

✅ Implemented: replace cloud Chat Completions with Responses streaming, reuse resource-owned HTTP sessions, remove Assistant native Tools and duplicate /status handling. Full repository checks and unsigned iOS device build passed; the required Simulator build remains blocked by external CoreAI. Offline regressions cover protocol/cancellation/reuse, Action-only Assistant and history ownership. Real-provider latency, installation and physical acceptance remain separate; see Validation-History.


## 2026-10-10 — Responses assistant-history HTTP400 fix

- Prior assistant history now uses output_text with annotations=[]; system/user input_text and native call/result pairing are retained. Add request regressions for ordinary multi-turn history and assistant text accompanying function calls.
- A temporary user-authorized credential reproduced the official GPT-4.1 invalid_value error at input[2].content[0]. Corrected protocol and actual compiled Swift adapter probes completed successfully. Credentials are absent from repository/test fixtures; live evidence and device installation are recorded separately in Validation-History.md.


## 2026-10-10 — Specialist history grouped by task

- Settings history retains Assistant conversations/archives; Photographer, Memory and ApplicationControl show task-scoped input/model records, status and export. Original task-request titles replace conversation-summary headings.
- Read-only App projection uses one immutable Agent context snapshot, task scope and retained input evidence; related inputs/ReACT remain together across old conversation archives. Missing associations are separately labeled and missing dates remain empty. No context mutation, model summarization or second history store is introduced. Validation evidence is recorded in Validation-History.md.

## 2026-10-11 — 泛化 Task 与独立 Skill

任意任务目标替代固定 Task Mode，原子批量加载/释放 Skill、默认临时能力自动释放；单前台上下文与独立后台 send 协议、容量/取消证据分离。首页和历史展示目标、实际 Skills、执行者和父任务关系。旧状态恢复中断且不重放。自动及构建验收记录见 Validation-History.md。

## 2026-10-11 — Decentralized Action documentation and Skill teaching

Removed the central FunctionMetadata resources. @Action owns canonical doc and parameters; existing module registrations compile into neutral declaration projections injected by App. Examples belong to Skill Instructions.md, whose five built-in workflows now include prerequisites, branches, completion, failure handling and multi-round examples. History system-message limits match the existing 64 KiB prompt limit. Validation and Simulator limitations are recorded in Validation-History.md.

## 2026-10-11 — Channel-owned Action ordering

✅ ADR0213: deleted Action serialization keys and implicit cross-Channel/task exclusion. Preserve task-local Channel/wait FIFO and resource conflict/explicit takeover behavior. Supersede ADR0155 without rewriting historical validation evidence.

## 2026-10-11 — BasicSkill Task selection and goal completion

BasicSkill revision 2 explicitly separates short default-chain loadSkills from startTask for continuing multi-turn goals. Instructions require an explicit goal/completion condition, retain Tasks while waiting for user decisions, and distinguish confirmed completion, user cancellation, runtime failure and restart interruption. One-shot history query and multi-turn confirmation examples now follow these scopes. No runtime implementation changes; validation evidence is recorded separately.


## 2026-10-12 — Agent request errors continue with evidence

Shared Chat decisions now carry HTTP/provider, parsing and observation-construction failures into bounded next-request retries. Failed attempts remain failed in history while the same input/Task may recover; accepted executions join before continuation and native call/result pairs stay complete. BasicSkill revision 6 teaches this boundary. No provider switch or automatic device-effect replay; cancellation, budget exhaustion and unavailable durable/feedback evidence terminate explicitly. Validation is recorded separately.


## 2026-10-12 — Result-driven ReACT (ADR0214)

Removed explicit feedback registration attributes, host projections and role defaults. Joined rounds now continue on actual business output or execution failure and stop after successful completion without business output. Empty values remain values; empty successful reports/admission receipts remain acknowledgments. Preserve Task terminal/cancellation rules, native pairing and Agent failure retries. BasicSkill revision 7 teaches these rules. Validation is recorded separately.


## 2026-10-12 — Assistant prompt compaction

Keep resident RobotInteraction and all function/runtime contracts. Compact Core/role/Skill/catalog layers and Task fact projections; validate identical capabilities and model workflows against exported baseline (6593 default / 8754 first photography continuation input tokens). Targets 4500/6000 are acceptance metrics, not runtime limits. No new module, directory or project dependency.

## 2026-10-12 — ModelKit Support ownership

Shared code moves into Support/Core, Support/Backends, Support/Management and Support/Speech/Apple. Management and Defaults share a directory while retaining explicit independent compilation; HuggingFace remains a separately injected downloader. Concrete Gemma/Nemotron/Kokoro/MOSS/YOLO engines move to their model owners, mixed-model FluidAudio/MossCoreML targets are removed, and inference workers reuse one cancellation controller. Current source/build/test documentation is reconciled; historical model evidence and the original Word design are preserved. Validation successes and limitations are recorded in [the migration record](../completed/ModelKit-Support-Plan.md).

## 2026-10-12 — Intrinsic Action timeouts

Restore a mandatory base-layer execution budget, rename estimatingDuration to dynamicTimeout, execute composed budgets automatically, reuse child function contracts and remove redundant NexArm composition/unused estimates. Explicit UI and playback budgets preserve their completion boundaries; cooperative cleanup and physical-stop limitations remain.

## 2026-10-12 — Neutral ModelKit Core contracts and layer audit

Replaced inference conversation naming with opaque scopeID, separated resource residency from manager registration state, and moved production loader/waiter defaults to Management through explicit validated Core injection. Added independent Core typechecking and complete target dependency/import guards, migrated callers/fixtures, and added six boundary regressions. [The complete audit](../completed/ModelKit-Decoupling-Audit.md) records all 66 source owners and distinguishes a unified base SDK from independently compiled implementation targets. Full-suite timing and simulator dependency limitations remain explicit.


## 2026-10-12 — Complete ModelKit SDK dependency enforcement

Confirmed the entire 15-target ModelKit SDK has no other project-module dependencies. Strengthened the checker with explicit system/third-party import allowlists, third-party product/package ownership, source confinement and SDK target/product transitive closure; eight in-memory invalid cases are rejected. Model algorithms and runtime behavior are unchanged. The shared repository package remains; no standalone publishing package was added. [SDK audit](../completed/ModelKit-Decoupling-Audit.md) records ownership and [validation](../validation/Validation-History.md#2026-10-12--complete-modelkit-sdk-dependency-enforcement) separates the latest successful full automated run from iOS and runtime acceptance.


## 2026-10-12 — ModelKit current documentation and diagram alignment

Audited all 28 ModelKit directory READMEs, revised 27 and retained the accurate CoreML contract. Reconciled the complete 15-target/23-edge dependency diagram, provider/helper runtime flows, configurable Management limits, CoreAI actor/admission semantics, PCM downmixing and worker/terminal-event cancellation. Integrated current OpenAI protocol contracts and removed migration/regression records, obsolete implementation descriptions and application timer/storage policy from SDK source READMEs. Historical evidence remains under docs; no production code or interface changed. [Documentation history](Documentation-History.md#2026-10-12--modelkit-current-design-documentation-reconciliation) and [validation](../validation/Validation-History.md#2026-10-12--modelkit-current-documentation-and-diagram-alignment) record the review.


## 2026-10-12 — ReACT mechanism and limit design audit

Consolidated current ReACT contracts in MobileHarness/README.md Part III: result/error triggers, complete barrier, FIFO/context/Skill refresh, finishTask versus cancelTask, per-input cumulative budgets, request/parser/provider limits and terminal failure boundaries. Removed obsolete policy-driven and 30-second/60-second Agent timing descriptions, and corrected result-delivery retries to match current lifetime ownership. The design explicitly records absent transient-error classification/backoff, automatic context shrinking and generic activity-driven Chat continuation. Runtime code was not changed by this documentation audit.


## 2026-10-12 — Composed listening feedback Actions and wake animation

UI.Feedback.playCue and vibrate are canonical bounded Actions registered by UIModule and taught by ExpressionInteraction revision 7. Cue selection supports wake/confirm/cancel/error/soft and volume 0…1; haptics support five styles, intensity 0…1, 1…3 pulses and 40…250 ms spacing. Unsupported hardware, overlap, invalid arguments and missing bindings fail explicitly. App owns actual audio/haptics, and PlatformKit remains a generic native capability.

Speech.Listening.update now validates configurable wake feedback and awaits the root-owned startup composition. Canonical child invocations inherit trusted causal/session context with separate execution IDs. Haptic/readiness join in parallel, followed by cue/native drain and a 120 ms acoustic tail, then microphone readiness. Stage failure blocks later capture and retains actual child outcomes. The parent declares 90 seconds; readiness/capture each use the existing 30-second default and feedback children 5 seconds. Startup cancellation invalidates only the matching startup ID and joins native cleanup. Ordinary reply pause/resume does not replay effects; existing half-duplex, user-off interruption and closed resting eyes remain intact.

The default haptic changes from soft/0.8 to heavy/1. Original wake synthesis changes from the 420 ms ascending cue to a 0.94 s bell-like F-major profile using the supplied video as a spectral/timing reference. No user recording, private system sound or third-party sound asset is packaged. Public Siri sound demonstrations exist, but no official downloadable activation asset or precise Apple Intelligence haptic parameters were found; similarity is a recreation and needs audible/physical comparison.

Waking eyelids now use a fast 180 ms cubic ease-out, retain stable shape identity and start a new blink/breath epoch. Closure remains a softer 460 ms transition. The first 1.2 seconds suppress blinking, and loading no longer scales the eyes. The single-pass GPU rim has stable full-screen bounds, a 320 ms native fade in/out and a softer 1.05 s multicolor activation bloom. Reduce Motion remains static with 200 ms fades. Source-derived previews and actual device acceptance are distinct.

The generic activation helper moved from Presentation to existing Speech workflows; AppSpeechPlayback adds the existing Actions/ExecutionRuntime dependencies. Shared boundary guards reflect that narrow dependency change, and the robot test-only UI fixture registers the new canonical feedback definitions with explicit unavailable native support. No new directory, dependency package, credential or signing-source change was introduced. Validation and installation evidence is recorded in [Validation History](../validation/Validation-History.md#2026-10-12--feedback-actions-and-fast-wake-validation).


## 2026-10-12 — VAD and ActionCatalog compiler-warning cleanup

VoiceActivitySegmenter explicitly discards the unused SpeechBoundaryPolicy.consume result while retaining the existing streamEvents path. ActionCatalogMacro implements the current MemberMacro expansion signature with conformingTo instead of relying on the deprecated compatibility default; generated declarations and factory collection remain unchanged. Reconciled the owning READMEs and removed their stale sixty-second utterance-limit statement. Existing unrelated working-tree changes were preserved.


## 2026-10-12 — Saved and discarded photo departure effects

The current photo now exits on both successful save and ignore. Save commits the add-only Photos import first, enlarges the thumbnail to 1.16 over 180 ms, then slides wholly past the right edge over 420 ms without shrinking. Ignore slides toward the lower-right outside both screen edges and shrinks to 0.06 over 520 ms. Controls disappear when departure is admitted; full-screen inspection waits for actual dismissal before starting the thumbnail animation, with one request-ID fence. Reduce Motion uses a 200 ms fade.

PhotoDeparture owns one identity-fenced renderer acknowledgment; PhotoDispositionWorkflow joins the committed native decision, visual completion and sound, then CameraCoordinator removes only the matching current photo component. New capture creates a fresh UUID/component. A failed import retains the photo and starts no success feedback. Cancellation after actual import preserves the save and joins effects/cleanup. Exact duplicate saved UUIDs return alreadySaved after UI removal, without replaying import or effects. Ignore removes preview UI, not album images or private reasoning evidence.

UI.Feedback.playCue gains save/discard profiles: an original rising save chime and a falling filtered-air/crumpling discard cue. The camera reuses the canonical Action factory and 5-second execution budget through a private scoped native capability. NativeCuePlayback owns one AVAudioPlayer with a UUID-fenced immutable delegate; it does not explicitly reconfigure/deactivate the shared audio session and never resets recording or the speech player. Portable PCM16 encoding validates format and one-second bounds before native playback. All seven cue profiles remain finite, ramped and generated from source; no media asset/dependency package was added.

CameraPhotoCommandReceipt optionally carries bounded feedbackIssues so a feedback problem cannot be reported as a failed album import. ExpressionInteraction revision 8 exposes the expanded cue vocabulary; Photography revision 13 teaches automatic effects, actual-save versus feedback issues and no duplicate cue. Source directories/module dependencies are unchanged. Validation distinguishes portable contracts, source-derived motion preview, native build and physical-device acceptance in [Validation History](../validation/Validation-History.md#2026-10-12--photo-disposition-animation-and-cue-validation).

## 2026-10-13 — Photo archive capacity and coordinated native home animation

The device photo metadata audit found exactly 32 durable records totaling 4,493,177 bytes: the default count bound caused repeated takePhoto capacityExceeded. App now supplies a bounded 1024-photo/2 GiB archive and 512 KiB index. Storage retains reusable validated caller limits and original 32-photo defaults. Existing IDs/owners/files survive migration; encoded-index overflow rejects before adding a JPEG. Under the explicit App FIFO policy, oldest private cached JPEGs retire after a committed new record when count/bytes/index are full; album images are unaffected. SDK default reject policy remains available.

The foreground goal now owns a fixed small line above the promoted ASR slot; only ASR moves between live/final positions. NativeCompanionSurface replaces separate SwiftUI eye/halo clocks with one monotonic, listening-generation-scoped commit. CAShapeLayer interpolates identical cubic eye paths on Core Animation, with 180 ms waking, 460 ms closing and presentation-value interruption. Metal uses a cached compiled pipeline, one premultiplied pass and CAMetalDisplayLink on an owned render thread. The rounded activation front converges from center to rim every generation, with one reversible fade envelope. Work is bounded to one latest snapshot/coalesced wake and three GPU commands; disposal invalidates and joins off MainActor. ProMotion is enabled through public configuration; actual frame pacing remains measured separately from requested refresh.

Apple primary references informed the implementation: [Core Animation](https://developer.apple.com/documentation/QuartzCore), [explicit CAShapeLayer path animation](https://developer.apple.com/documentation/quartzcore/cashapelayer/path), [SwiftUI performance](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance), [Metal display link](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink) and [ProMotion](https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays). A DEBUG-only isolated six-cycle preview supports native tracing without mic/camera/model startup. Required checks, signed installation and separate synthetic-device acceptance are recorded in Validation History. No new directory/module/dependency or data reset is introduced.


## 2026-10-13 — Completion-owned decisions, FIFO photo cache and visible home failures

Removed the fixed four-request cap in shared Chat and both history request/round arrays, cumulative sixteen-native caps in Chat/transport, and the history-wide 128-call stop. Production AgentTaskBudget records usage with nil optional count limits; explicitly configured SDK limits remain valid. Per-generation call/feedback bounds reset. Native queues admit one complete bounded generation (128 envelopes) while preserving four concurrent executions and sealed-round joins. Completed model-context blocks retire oldest first when space is needed; original intent, system, latest result and complete native pairing remain, while exact durable history stays intact. Repeated identical failed recovery with no successful business output returns the real error rather than looping indefinitely.

App photo retention now selects evictOldest. Count/bytes/index overflow retires oldest cached records automatically; commit happens before file reclamation, and failed index publication removes only the incoming JPEG. Unindexed-file reconciliation retries cleanup after interruption; historical retired references are absent. Agent/Action failures, including HTTP 400, additionally appear in a fresh, deduplicated home toast below the eyes, independent of voicePhase. Close/expiry/new live ASR dismiss only the toast and preserve detailed evidence.


## 2026-10-13 — Execution evidence no longer requests ReACT

Per user-approved clarification, AgentActionCompletion business-output classification now recognizes only explicit value, including an empty value. Successful execution reports and activity handles remain terminal execution evidence without extra model calls; actual failures/partial failures/cancellation, failure codes and Agent request/observation recovery still trigger reasoning. Reports are retained in history, ledgers and the full barrier. BasicSkill revision 14 teaches the distinction. Expanded Action/Tool/mixed report regressions and synthetic NexArm recovery assert continuation from actual values/errors rather than report presence. No report deletion, per-Action feedback flag, effect replay or unrelated runtime/quota change was introduced.


## 2026-10-13 — Contact-origin listening light

- Replaced the hollow expanding rounded rectangle with a soft contact-point flash, circular radial wave and filled luminous tail. Edge arrival is based on distance from the source; cyan/blue/violet/pink/amber rim flow and reversible fade remain in the same Metal pass.
- Added UI-owned `ListeningLightOrigin` normalized parameters and `ConversationState.listeningLightOrigin`. Production captures the initial hold location in content coordinates; the native surface maps through safe-area offsets to the full-window layer. Accessibility uses the eye-center default. The source is latched to each new listening generation, preventing passive state updates or a later press from moving an active wave.
- Retained shared native eye/light timing, reduced-motion behavior, one coalesced state slot and three in-flight GPU frames. No device or Action lifetime changes.
- Live underwater refraction is not implemented: Apple's SwiftUI distortion API warns UIKit-backed views may not render into its filtered layer; this surface includes native camera, Metal and eye layers. No frozen backdrop or per-frame screenshot fallback is used.


## 2026-10-13 — Compact upper-layer home notices

- Action snapshot failures remain in the colored current Action panel and no longer create or replace a toast. Call-scoped native issues retain full execution evidence without offering a toast; mixed failure snapshots select the newest eligible upper-layer issue.
- Fresh Agent output and App/runtime/system failures continue to offer a bounded, deduplicated notice. Historical/stale snapshots do not replay notices; dismissal remains identity-fenced and does not remove logs.
- Replaced the large material card, heading, scroll area and close button with centered yellow text and an inline warning icon, up to three lines. The lower reply/hint slot yields during the eight-second notice; no touch interception or task/ASR movement is introduced.


## 2026-10-13 — Immediate contact flash and native-start feedback

- Listening activation admits readiness and the canonical cue/haptic children together. A context-fenced, single-waiter native-start gate holds the haptic until the first cue buffer is scheduled and the native player is started. The requested haptic generator prewarms before waiting; cue generation remains off MainActor. Real cue failure/cancellation releases the gate with that error, and startup cleanup retires only its own gate.
- Platform audio exposes an optional once-per-operation first-buffer/player-start acknowledgment. Existing PCM bounds, actual drain and cancellation/session cleanup remain intact. This is a native admission boundary, not a guarantee of exact acoustic onset on every route.
- Preparation, cue drain and haptic completion must all succeed before the existing acoustic tail and microphone admission. A failed preparation can retain real intent feedback while still preventing capture; canonical partial reports are not rolled back or fabricated.
- Normal light activation starts at at least 0.5 opacity, with a larger/brighter contact flash and radial front. Entry rises to full opacity; reduced-motion behavior, settled terms and the existing exit smoothstep/duration are unchanged. Activation-only flash terms disappear by 0.9 s.


## 2026-10-13 — Hold-time output prewarm and stronger source flash

- Home forwards touch-down/release through an injected callback. Lifecycle owns one coalesced cancellable warmup and one default wake PCM cache; the output-only playback graph is connected/prepared/started during the hold. No microphone capture or sound is admitted by preparation.
- A recognized hold retains warm output ownership across Agent intent delivery. The canonical Listening cue/haptic Actions reuse prepared PCM/native output resources, avoiding cold graph/session setup after the light starts; native cue-start still releases the haptic. No extra confirmation playback or vibration path is introduced.
- Aborted press, stop and shutdown cancel/retire warmup; output preparation failure performs explicit rollback. Unconsumed warm resources are released only while no native capture/playback owner is active. Platform queues and PCM bounds remain unchanged.
- Normal activation begins at 0.85 visibility. Its existing Metal pulse temporarily composites above the eyes for 0.9 seconds, then returns to the original settled stacking, so the source cannot be hidden by opening eyes. Reduced-motion/static and the existing exit curve remain unchanged.

## 2026-10-13 — Actions shared Support organization

✅ Grouped the existing neutral contracts under Actions/Support/Contracts and shared macro/catalog utilities under Actions/Support. Preserved six domain owners and the independent FunctionContracts compilation boundary; aligned current design, package paths, Xcode navigation and architecture checks. [Validation](../validation/Validation-History.md#2026-10-13--actions-shared-support-organization) records passing full checks and the existing CoreAI Simulator build limitation.


## 2026-10-13 — Actions current technical documentation

Rewrote all 15 Actions READMEs from current implementations, with direct upstream/downstream and internal relationship graphs, interfaces, key algorithms and completion/failure boundaries. Removed dated modification/acceptance appendices from technical documents and retained the earlier UI audit in Documentation-History.md. [Validation](../validation/Validation-History.md#2026-10-13--actions-readme-current-design-audit) records source consistency, link/diagram-structure/diff checks and the documentation-only scope.


## 2026-10-13 — Deterministic Agent evidence retention and startup failure label

- Physical ApplicationControl context contained 8192 records / 5047 consumed batches; fresh Assistant history v2 contained zero turns. Signal append without an explicit retention policy exhausted the Core limit, terminated ApplicationControl and closed the common settings transport. This explains the scopeClosed failure independently of chat schema compatibility.
- ApplicationControl, Memory and Photographer now retain the latest 4096 evidence records/batches, count evictions and converge valid saturated documents on their next atomic input commit. Business state, model preferences, model files and Assistant raw/indexed history are not reset. Startup UI says application preparation failed, because preparation also restores Agent-backed settings.
- Regression coverage includes saturated context admission, subsequent requests, native call selection, root settings/Gateway restoration, persisted retention after reopen and original speech preference preservation. Device/native acceptance is recorded separately in Validation-History.


## 2026-10-13 — Per-conversation checkpoint storage v3

Replace Assistant aggregate context persistence with current.json, independent conversation-ID archives, a metadata index and recoverable rotation. Delta boundaries are removed; complete response strings and execution evidence update memory, with user admission and decision terminal checkpoints. Explicit close/cancellation saves changed recovery state; crash may lose unsaved output. Archived bodies load only on selection, including archive Task browsing. Shared prompt/request text is deduplicated on disk; file locks are isolated per path. Title work is root-owned and independent of new-conversation/page completion. No old format decoder/import remains. Earlier Task indexing and exact native call/result evidence remain intact.


## 2026-10-14 — Whole-row Task disclosure

Task timeline summaries now toggle their source rows as one plain Button. Remove the separate expansion-control cell; align the trailing chevron with request rows, right when collapsed and down when expanded. Source count follows status as completed · N 轮对话. Preserve blue task metadata, icon-free child indentation, orange ReACT text/bottom badges, hierarchical separators and the existing single request destination. No persistence/backend contracts change.


## 2026-10-14 — History type icons and capsules

Top-level ReACT requests now use an orange cycle-arrow icon distinct from ordinary conversation bubbles and blue task checklists. Task summaries show a blue Task capsule immediately after status/source count. Task and ReACT capsules share one private styling helper. Expanded task sources retain their icon-free hierarchy. No data, sharing or navigation contracts change.


## 2026-10-14 — ReACT text hierarchy and single cycle arrow

All timeline requests now use primary color for input and secondary color for response, including ReACT source rows. ReACT remains identifiable by its orange type icon/capsule; replace the double-arrow loop with arrow.clockwise for a simpler single-arrow symbol. Task blue metadata/capsules, source indentation and navigation are unchanged.


## 2026-10-14 — Restore ReACT request tint

Restore orange ReACT request text in both timeline and expanded source rows per the clarified design. Response text remains secondary gray, providing distinct input/output emphasis. Single-arrow icon, ReACT/Task capsules and navigation remain unchanged.


## 2026-10-14 — Grouped request Task and Skills evidence

Tasks and Skills now contains responsive Task/Skills subpanels within one card: stacked on narrow layouts and side-by-side when readable minimum widths fit. Skill IDs/revisions become sorted, wrapping tinted capsules. Task mode/goal and selectable references stay together; Function Catalog remains in this section. Equal record-owner and request-time Task snapshot IDs render once with Active at request; distinct IDs preserve each role without claiming live activity. UI-only reference projection does not alter stored values or raw JSON sharing.


## 2026-10-14 — Structured request Function Catalog

Replace raw catalog JSON as the default presentation with grouped Actions/Tools counts and sorted alias/path entries. Per-function disclosure exposes recorded Channel, required/optional parameter names and Tool definition. Decode the request snapshot at view construction; malformed data remains a visible error with raw diagnostic JSON. Original Codable export and current registration/conflict policy remain unchanged: identical Skill bindings deduplicate; same path with differing callType/alias/channel, or a shared alias across distinct model functions, rejects without Action priority.


## 2026-10-14 — Agent records hub and canonical Assistant history

Settings now opens Agent 记录, a UI-local destination/view-injection hub with Assistant conversations as the sole implemented entry. Each future Agent can supply its own record type and page. Remove the duplicate Assistant task-history destination and archived-task pages, task aggregation reader/adapter API, task-only UI models/state/constructors/export, input-ID subset filtering, task-to-model-history callback chain and unused log input-ID payload. One root-owned Assistant ConversationHistoryWorkflow replaces the previous dummy root/second task workflow; selected-conversation readers are mandatory and enforce returned identity before caching.

Foreground Task requests, compression summaries and terminal status remain in canonical conversation files and expand in place, including after live TaskRecord retirement. Background/delegated execution state is not claimed as conversation data: real Task registries/Skill state and Home Task/Action/Agent diagnostic projections remain intact. No storage schema, old-format compatibility/import, model function or task execution policy changes. Current module documentation removes duplicated/superseded task-page and v2-file claims; historical evidence remains in the validation/change documents.

## 2026-10-14 — Model-only photo compression

Prepare an Image I/O JPEG only for model observations using App-owned 1568-pixel/1-Mpixel/1-MiB defaults, retaining original photo storage and album import. Reuse the prepared attachment through ReACT instead of recompressing each request; native work remains cancellation-owned and errors are explicit. Offline/native validation is recorded in Validation-History.md; physical quality/latency acceptance remains pending.


## 2026-10-14 — Canonical prefix-number identities

Historical intermediate design: the Identity compilation leaf and foundation numeric tokens described below are superseded by the foundation-isolation correction.

Application-generated UUID types and creation/parsing/truncation are replaced across framework, Agents, Gateway, Actions, Storage, ModelKit, PlatformKit, App and UI with RecordID. The independently compiled Identity leaf lives in the existing Storage directory; no new directory or third-party dependency is added. Durable per-prefix numbers reserve atomic batches before publication, remain separate from conversation deletion, reject missing/rolled-back/corrupt counters and propagate failure. Internal onset ownership uses an explicit recognition-binding enum instead of a zero UUID sentinel.

History now returns/accepts only conversation_number, removes short-ref aliases, uses schema v4 and direct ID filenames; LocalDocumentStore envelopes use v2. New NumericRecords/Settings/Photos/Bluetooth locations isolate previous UUID data without decoding/import/migration. App configures its counter source before services. Transient scoped fences and diagnostic IDs use independent numeric prefixes. Native Bluetooth UUID/CBUUID remains solely within the user-approved platform adapter and maps to durable device_number. External provider call strings retain their native association. Existing uncommitted image-compression work is preserved.

Validation outcomes and remaining full-suite/simulator/native limits are recorded in Validation-History.md. No commit or physical installation was requested for this change.

## 2026-10-14 - Business ID and foundation isolation correction

Remove Identity as a package target and compile the business ID value/allocator directly in Storage. ModelKit, PlatformKit, UI and Storage have zero cross-module dependencies. Capability interfaces accept opaque caller strings; native operation, inference lease, speech segment, animation and temporary-file identity uses Foundation UUID. Generic Storage document revisions and reader/expiry tokens also return to UUID. Upper business/framework clients explicitly consume Storage identities.

App owns bidirectional native Bluetooth/device_number mapping with an injectable allocator. Independent per-prefix locks allow concurrent in-memory allocation; only shared durable reservations/associations serialize. Fresh durable initialization establishes the empty counter document before UUID-only records can be written. No old-store migration, new directory, commit or installation is introduced. Final verification evidence and the remaining timing/Simulator limits are recorded separately below in Validation-History.md.

## 2026-10-14 — Assistant-owned model image preparation

Move analysis budgets and preparation invocation from ApplicationRuntime's hidden read side effect to AssistantContextBuilder. App injects raw read and generic native JPEG preparation only; Assistant supplies policy, checks cancellation/identity/output and constructs ChatImage. Retain original photo storage and ReACT attachment reuse; no new directory/module/dependency. Validation is recorded in Validation-History.md.

## 2026-10-14 — SQLite business-record migration

✅ Implemented SQLite/GRDB business-record migration. Complete messages/ReACT observations commit separately; runtime UUIDs replace the broad numeric allocator. Source windows, indexed pages, exact deduplicated snapshots, media pending/ready and device mappings replace JSON record indexes. Historical allocator evidence above is superseded; existing media/models/credentials remain untouched. Validation results are separate.

## 2026-10-15 — Storage repository and backend boundaries

✅ Implemented: domain directories, backend-independent contracts, separate SQLite compilation, interface injection and reusable File/Memory implementations. Preserve current SQLite record/schema and message/media recovery contracts; remove replaced aggregate entry and direct backend dependencies.


## 2026-10-15 — Preserve App configuration during SQLite adoption

✅ Restore Settings/settings.json, Models/download-source.json, Models/transfers.json, CapturedPhotos and unchanged File document envelope1. SQLite remains limited to committed business records/indexes. Keychain and installed models are untouched; changed Agent runtime snapshots alone keep isolated filenames. Fixed original-format regression tests pass and build2026101502 is installed/launched; native startup restores the existing cloud configuration. Full-suite timing failures and Simulator CoreAI dependency limits remain separately recorded in [validation history](../validation/Validation-History.md#2026-10-15--restore-app-configuration-paths-and-document-format).


## 2026-10-15 — Identity-first ORM records and memory-only runtime

✅ Existing GRDB ORM mappings allocate Task/message/dialog identities before use and update completed content/terminal state. Every production Agent Context now uses Storage process-memory state; Context JSON factories/fixtures and duplicated Task recovery snapshots are removed. Per-message/ReACT commits, zero delta writes, SQL-only interruption recovery, stable metadata and bounded memory remain explicit. Current configuration/media/credential/model paths remain unchanged. Focused tests,100000-message query benchmark and unsigned iOS build pass; full-suite timing/Simulator dependency limits and separate native acceptance are recorded in [validation history](../validation/Validation-History.md#2026-10-15--orm-identity-first-records-and-memory-only-agent-state).


## 2026-10-15 — Insert complete user messages once

✅ Final accepted user text inserts directly as completed with its durable ID in one transaction; no empty user identity is reserved. Assistant identity reservation, zero delta writes and independent ReACT commits remain. Failed identity publication retries the same committed row. Focused regressions and unsigned iOS device build pass; full-suite/Simulator limits are recorded in [validation history](../validation/Validation-History.md#2026-10-15--completed-user-message-admission-without-placeholder).


## 2026-10-15 — Recoverable current-dialog publication and write preconditions

✅ Atomic archive/new-current rotation now retains a memory-synchronization fence after SQL commit until publication succeeds. Read/admission/rotation boundaries resolve the database current; stale tokens or active/dirty mismatches reject without dropping work. Missing current creates through the existing transaction. SQL rejects new messages/identity reservations on archived dialogs while preserving existing-row late updates. Six dialog fault/concurrency regressions and delta/message/retry coverage pass; validation/build limitations are recorded in [validation history](../validation/Validation-History.md#2026-10-15--current-dialog-publication-recovery-and-write-preconditions).


## 2026-10-15 — Remove unreachable feedback catch and install build2026101503

✅ InputGateway.deliverFeedback no longer wraps nonthrowing UUID/envelope construction in an unreachable catch. Existing owner/hop/admission diagnostics remain. Signed build2026101503 is installed and launched on the physical iPhone;18 focused cases pass. Full-suite timing failures and the Simulator CoreAI dependency limit remain separate in [validation history](../validation/Validation-History.md#2026-10-15--feedback-warning-fix-and-physical-installation).


## 2026-10-15 — Restore expandable Task records with SQL pagination

✅ Fixed UI Task folding after the SQLite paging migration: a loaded source subset is checked against exact recorded input/request pairs instead of requiring all Task sources on the page. Timeline and expanded Task pagination retain per-page compression metadata. Real SQL regressions distinguish durable source rows from the missing Task card, exercise the second page, read raw details and reopen an archived Task. Existing row styling/navigation remains. Validation evidence and build/native limits are recorded in [validation history](../validation/Validation-History.md#2026-10-15--expandable-task-history-after-sql-pagination).


## 2026-10-15 — Automatic history paging with scoped retry

✅ Archive lists, conversation timelines and expanded Task sources load their next50-item page when the lazy-list footer appears. Per-cursor tickets prevent duplicate/overlapping attempts; failed pages retain visible records and expose manual retry. Page-scoped tasks cancel on disappearance/collapse, ignore late responses and re-arm after cancellation completes. Existing Task metadata merging, row styling and navigation remain. Checks and native limits are recorded in [validation history](../validation/Validation-History.md#2026-10-15--automatic-history-paging-with-scoped-retry).


## 2026-10-15 — Native history refresh and paging indicators

- Conversation timeline adds native List pull-to-refresh; archive list retains the same system gesture. Automatic archive/timeline/Task paging shares an unlabeled system spinner with an accessibility label and scoped error/retry. No custom refresh/insert transition or visual/navigation redesign.
- Timeline refresh fences previous page tickets, retains Task expansion and visible records on failure, and clears source caches only after successful first-page reload. Visible expanded Tasks then fetch fresh pages through their existing footers. Archive refresh cancels and joins its bounded page reader before first-page replacement; business mutations are not cancelled or overlapped. No storage/schema/model or Task lifecycle change.
- State and workflow regressions cover stale-page rejection, cancellation/join ordering, refresh failure retention and resumed paging. Native gesture/animation acceptance and physical installation remain separate.


## 2026-10-15 — Twenty-item history pages

- Archive dialogs, conversation timeline and expanded Task sources now default to20 rows through StorageChat.HistoryPaging.pageSize. Archive EOF and response-size validation share the same constant. Raw-message internal enumeration batches and existing query limits remain independent; no stored records/schema change.
- Regressions use20-row archive boundaries, a32-source Task across20+12 pages, later-page Task folding, complete raw reads, and an unchanged100000-message corpus with20-row preview assertions. Native loading/refresh styles remain unchanged.


## 2026-10-15 — Retain paged history when returning from details

- Both archive dialog List and message timeline previously performed first-page refresh on every .task reappearance. Popping a child destination replaced accumulated pages and Task source caches, shrinking the List and losing the prior scroll range.
- Add a view-scoped initial-load gate shared by both page types. Successful initial reads are not repeated on Back; failed/cancelled initial reads remain retryable. Explicit refresh/retry retains its existing first-page reload contract, and failed refresh cannot reopen automatic initial loading. Conversation destinations use stable dialog identities so a different dialog creates its own page state. No query, schema, pagination size or navigation-stack redesign.
- Keep native List identity/row identifiers and existing Task expansion/source pages on child return; do not introduce forced scrollTo or custom Back animations. Added lifecycle-state regressions; actual native offset/gesture acceptance remains separate.


## 2026-10-15 — Merge one-packet NexArm tracking into main

- Integrate feat/main-sh commit724c4fd9 into main's existing framework. Tracking now sends one synchronous motors1/4 packet per admitted target through Actions-owned NexArmAimCommand; shoulder/elbow remain uncommanded. Preserve main's FunctionContracts, Agent/Skill services, String connection sessions, bounded native recovery, foreground/resource fences and cancellation/terminal reporting.
- Resolve README/navigation/test conflicts using main's current structure. Remove obsolete four-motor streaming state from the live worker, clear the new command state on main's connection cleanup path, and preserve manual jog/finite-motion algorithms. Adapt late-error regressions to submit a new target and verify that a held target no longer generates writes.
- Preserve both branches' physical evidence. Renumber the branch's one-packet decision to [ADR0215](../adr/0215-nexarm-aim-one-shot.md), retaining main's distinct ADR0142 Bluetooth-lifetime decision. Validation and remaining simulator/physical limits are recorded in [validation history](../validation/Validation-History.md#2026-10-15--merge-main-sh-one-packet-tracking-into-main).
