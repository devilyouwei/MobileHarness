# Settings — 设置、资源、设备与历史

## 职责与接口

本目录只拥有 UI 草稿、事实快照、历史展示及注入的请求接口，不依赖 Storage、Agents、Actions 或设备 SDK。业务集成执行保存、模型资源操作、连接及历史读取，并回传版本围栏下的 UI 值；导航和编辑本身不提交业务。

## 按功能归类

| 功能 | 状态／子容器与接口 | 页面 |
| --- | --- | --- |
| Provider 设置 | SettingsState、UISettingsContainer、SettingsProviderOperations | SettingsView |
| 模型资源 | ModelResourcesState、UIModelResourcesContainer、ModelResourcesOperating | ModelResourcesView |
| 蓝牙展示 | BluetoothSettingsState、UIDeviceSettingsContainer | BluetoothSettingsView |
| 历史记录 | ConversationHistoryState、UIHistoryContainer、ConversationHistoryPresentation | ConversationHistoryView |

各子容器、呈现协议及请求接口与所属状态同文件；导航由 UI 根提供。音频检测属于 Diagnostics，本目录仅嵌入其公开 Section，不复制状态或控制实现。

## 表单与资源

Provider 草稿包含地址、模型和密钥，不写入模型历史／用户日志。发现、恢复、保存保留草稿 revision，迟到结果不覆盖新输入；页面离开取消发现任务。根停止清除敏感草稿。

资源界面按目录 ID 展示识别、合成、语言和视觉，接受宿主提供的安装／下载／删除／取消及偏好事实；刷新保留 generation。下载不自动开启自定义语音，资源资格由宿主判定。

## 设备展示

BluetoothSettingsState 分开呈现可用性、发现、连接、传输问题、控制资格及恢复阶段。点击未连接设备提交连接意图，已连接设备打开本地详情；滑杆释放／停止提交实际停止意图。连接事实不代表物理动作验证。

设备子容器在 UI start 前只暂存一个最新快照，start 应用 UI 值但不查询设备；停止清除待应用值。真正连接、恢复、控制 worker 和清理属于外部能力拥有者。

## 历史值、分页与导航

Settings routes directly to injected Assistant chat records and Writer workspace records through assistantHistory/writerHistory; there is no intermediate records hub. Original model requests remain the source of request rows.

Task 压缩行以实际 historyTaskID、input/request 来源对及 historyOrder 校验，在原请求位置展示；展开源记录独立分页。不同 Task 的 source、request-time task 快照和 live execution 状态保持区别。缺失证据不补造。

页面保留20项游标分页、ticket／generation、首次成功加载门和显式重试。最多16个 Task 页读取，超额显式拒绝。取消只释放匹配 ticket；完成 revision 唤醒被取消的可见 footer，不由开始读取自行取消任务。

下拉刷新取消并加入时间线与 Task 读取后重置分页，刷新失败保留已有内容；从详情返回不重载成功页或重建列表，保留展开和滚动位置。不同会话以稳定 ID 隔离。请求详情使用一个选择值和一个 navigationDestination，重复点击不累加导航。

## 历史展示与导出

Task／ReACT 标签、状态、来源数量及分层缩进分别表达真实证据；Assistant 详情依次展示 User Request、Assistant Response、Tasks、Skills、States、Function Catalog、Prompts、Generation Meta 与页尾日志清空按钮。Tasks、Skills、States、Function Catalog 位于同一个业务 Section，按同级内容组排列，分别使用蓝色 checklist、紫色 square.stack.3d.up、橙色 square.stack.3d.down.right、绿色 function 图标。States 展示该轮记录的实际选择路径，缺少证据显示 Not recorded，记录为空显示 None。Prompts 只显示格式化消息、图片和工具定义；不展示完整请求/模型返回日志原始 JSON，也没有 Action Execution 区块。结构化 Function Catalog 只解析记录时的 schema，一次解析并保留错误与原 JSON，不回退为当前注册表或虚构空结果。

Function Catalog 为独立平铺 Form 行，展开状态为页面局部值，避免嵌套交互行接管点击。Token 用量只显示已报告的值，包括可选缓存读写；零与缺失不同。

JSON 分享延迟编码实际展示的 Codable 值，保留原始 requestJSON；prettyPrinted/sortedKeys、默认日期编码，最大32MiB。取消／编码错误显式传播，不创建临时仓库数据或空导出。

历史图片仅解析结构化引用，按身份去重并限制展示数量。全屏检查器使用共享 RetainedFullScreenCover 保留下层首页；页面图片解码／读取仍随离开取消。

## 接纳与失败

子容器统一创建状态，业务只读协议＋类型化提交；根停止后拒绝更新，后台允许保留事实。设置 revision、资源 generation、分页 ticket 独立于根接纳。

[UI 根](../README.md) · [音频检测](../Diagnostics/README.md)

历史消息读取有页面所有者、取消／身份校验与加入；目录在通用执行器解析，按原JSON身份缓存，时间线仅随加载／分页重建并预分组。资源下载源编辑提交窄控制接口，页面不轮询自动保存；外部唯一工作流合并初始恢复并拥有防抖、停止与错误上报。

历史详情读取的容量约束：一个实际读取与一个最新候选，取消清除候选并取消实际读取；候选替换不创建等待任务链，实际读取完成后才接纳下一项。

已实现：devices呈现Action维护独立连接摘要，设置页展示该状态；详细设备／机械臂控制资格仍消费原真实状态，不由显示摘要解锁设备。

## Direct container contract

UI-owned typed request/reply capabilities have one consumer and at most 64 outstanding requests, including accepted work. Acceptance does not complete a request. Cancellation, consumer exit, root invalidation and late replies are generation-fenced. Foundation dependencies remain empty. Current cross-module ownership is defined by the [overall design](../../README.md).

## Agent-owned UI inputs

Settings, resource, device and history subcontainers own their typed request/reply sources and UI generations. Business consumers are constructor-injected owners outside UI; pages and local interaction facades submit through these sources. UI contains no business event subscriber or Gateway dependency. Actual query/effect failure remains a failed receipt, with late completion fenced by generation.

## 直连链路当前契约

未提交表单和页面状态留 UI，业务提交、结果与运行事实的呈现归 Actions。

## Provider 表单控制

SettingsFormController 只拥有草稿规范化、默认选项、请求忙态和迟到结果围栏；经 SettingsOperating 提交 UI 自有请求，不导入业务或设备模块，不执行凭据持久化、模型切换或实际 Provider 发现。根持有控制器，页面退出取消发现并推进 revision。

## 多 Provider 管理

Agent Brains 总页依次展示 Cloud Providers、Assistant／Writer／Decision 子页入口和本地模型下载。角色入口整行可点，标题和状态使用系统主、次正文色。Provider 列表按名称和 URL 显示，支持添加及左滑编辑／删除；总页草稿随导航保留到离开 Agent Brains。子页各自持有草稿，返回时放弃未保存的编辑。根 SettingsFormController 在共享已提交快照上合并当前页改动，成功后发布；失败保留草稿。Provider 凭据留在既有私有设置链路。下载区使用统一下载源，按模型身份管理 Gemma 4 E2B 与 D3 Decision。

Provider 名称与稳定 ID 是当前文档的必填字段，通过私有配置链路保存。新增/编辑采用独立 modal 草稿（name/url/key），默认生成未占用的 Provider N 名称；取消不修改选择和凭据，确认校验 URL 唯一性与名称。列表名称为主、URL 单行省略为辅，保留三字段粘贴和 Key 脱敏。

ProviderEditorDraft 同时接纳 HTTP 与 HTTPS（域名或 IP，可带端口和路径）；保留名称、URL 唯一性、凭据长度和容量校验，错误提示不再要求仅 HTTPS。实际网络策略见 [Config](../../../Config/README.md)。

Implemented: Provider URL input is optional. Blank/whitespace input resolves to https://api.openai.com/v1 on modal confirmation, sharing the same URL identity as an explicit official endpoint. Keep name/key, duplicate checks, and nonempty HTTP/HTTPS validation. Cover default resolution and duplicate default providers.

## 用户板块入口

SettingsView 首页使用英文标题、分区、入口及蓝牙状态摘要；User 区依次呈现 Album、My Assistant、My Writer、Memory。Memory 为无点击行为的静态 Label；其余入口直接进入各自注入的页面，记录入口不经过聚合页。AI Models 和 External Devices 保持原有分区及入口顺序。蓝牙入口使用同文件私有矢量 BluetoothSymbol，其余入口图标不变；子页面及历史正文独立维护语言。

## 基础相册实施契约

启用相册导航，时间倒序网格每页40项、详情缩放、最多20张系统选择器导入、单张导出及确认删除。记忆保留静态项。长操作由根持有，页面退出不取消已接纳变更。

删除回执区分逻辑删除成功与文件清理问题；逻辑提交后即从当前UI列表移除，清理失败明确提示并保留恢复状态。

详情展示采用原生 Image I/O 最长边4096像素的按需显示图以限制解码内存，UIScrollView提供1～5倍缩放；导出始终读取原片文件，不导出显示图。

## Container 上下文

UIAlbumContainer.ContextSnapshot 提供内容状态、当前已加载数量、后续页标记及importing/exporting/deleting操作。导航公开相册详情对象、照片选择器／删除确认框，以及历史列表、对话及轮次详情。局部内容变化只能更新当前确认位置；过期代际拒绝。离页不取消根拥有的相册变更。

## Execution ownership and lifecycle

SettingsFormController retains up to 32 active/cancelled discovery workers. Overflow reports an explicit UI error. Cancellation advances revision immediately, while shutdown closes new work and cancels/joins every retained worker. Actions invokes this UI-owned cleanup through its injected facade; UI imports no business module.

## Passive state observation

The owning stateSnapshot entry point reads current local business/capability values and runtime admission/work facts in the owner's isolation domain. It performs no action, acquisition or device activation. The module root composes the explicitly selected fields; unknown diagnostic coverage is not healthy evidence. Domain-specific completion and failure contracts above remain authoritative.

Album State includes content and operation alongside list facts. Device recovery machinery is Runtime; visible connection/scanning are Business.

Settings Business.enabled is the editable cloud switch, loading is provider/model discovery, and saving is a settings write. Resource itemCount counts presented catalog entries; saving is source/custom-speech preference persistence, not download activity. These meanings are included in descriptors. Form operation failures are typed Business problems and album load failure is Business.content=failed; UI engineering health remains unknown without actual presentation-health evidence.

The State operation attribute belongs to ui.album. ui.navigation reflects navigation-owned facts only; its State projection does not include the album operation. Existing typed UI context composition remains a page-rendering interface.

## Album video presentation

Album items carry MIME; video/quicktime shows a play badge and opens a local-file player using AlbumInput.video → AlbumReply.video(URL). Thumbnail requests remain image Data and are decoded by the existing thumbnail renderer. Export/delete share existing typed requests and busy/admission behavior, with media-aware labels. Leaving detail clears the URL/player. The photo picker still imports static photos only; video capture comes from Camera.

SettingsInput/Reply、ResourcesInput/Reply、HistoryInput/Reply、DeviceInput分别与SettingsState、ModelResourcesState、ConversationHistoryState、BluetoothSettingsState同文件；通用传输位于Shared/UIRequests，具体输入类型由本目录拥有。

模型表单包含独立 Writer Provider 与模型名称。Provider 具有稳定 id，编辑 URL 保留 id；Writer 选择通过既有设置事务保存，不改变 Assistant 选择。

## Writer 记录与作品

UIHistoryContainer owns Assistant conversations. My Writer 的上方入口显示真实委托总数，详情展示来源、原始输入、状态、结果、前序消息与 workspace 链接；下方是 workspace 列表，使用 workspace 标题和消息数量。Workspace 详情没有委托分段；单条消息保留来源身份。工作区消息和委托列表从最新记录开始，使用现有历史列表的底部加载组件自动追加旧页。每个游标最多一个在途读取，失败保留行和游标并允许重试。页面保留已加载行与成功标志，子详情返回时复用，下拉刷新成功后从最新页开始。工作区定时刷新头部状态并合并新增消息，保持旧页游标。委托详情中的前序消息仍按原顺序读取。完整模型证据按消息身份按需加载。

Workspace titles and Assistant conversation titles use the same HistoryRecordRow: a vertically centered 20pt icon in a 24pt column, body title with two-line tail truncation, 6pt gap, caption metadata and 12pt vertical padding. Assistant icons are blue; Writer icons are muted purple. Titles use primary text and separators begin at the text column. My Assistant keeps Current Conversation/Past Conversations and New Conversation; My Writer opens the workspace list directly. Assistant metadata shows actual turnCount (falling back to loaded turns only when absent) and createdAt, never an inferred last-active date. Writer metadata shows stable workspace ID, cumulative requestCount and updatedAt; a reusable workspace has no latest-execution status badge. Metadata and dates share a line where space permits and stack at narrow widths/large text sizes without dropping fields. HistoryListPresentation formats dates in the supplied/current calendar and time zone as MM/dd HH:mm or yyyy/MM/dd HH:mm across years. Workspace header combines a vertically centered purple icon with a text column: small secondary monospaced workspace ID above the full wrapping title. Start time, update time, total rounds and file browsing follow in that order. Workspace conversation export is an icon button in the top-right toolbar, retaining the existing share and failure flow. Request-row number badges use smaller subheadline digits and remain gray, red only for failed requests; titles, retries, timestamps and state capsules remain unchanged. WriterArtifactsControlling owns snapshot reads, native previews and source/ZIP/PDF export.

模型发现按稳定 Provider ID 缓存。子页进入时刷新该角色的已选云端 Provider，切换时查询新选择。凭据变更提交后，控制器清除对应缓存。同一 Provider 的模型列表可供多个角色使用，各角色单独保存模型选择。结果经 ApplicationControl/Gateway 返回，凭据快照和请求 ID 围栏迟到结果。最多 32 个查询（含尚未退出的取消任务），溢出时显示错误。离页取消，根关闭加入，发现失败可重试并保留已选模型。

Provider 左滑删除先显示原生确认弹窗，取消不改变草稿。保存按钮保留忙态，实际保存回执完成后显示成功（3秒）或失败（6秒）Toast，不再占用常驻表单行；失败保留实际错误。页面只有一个可替换 Toast，展示计时随页面取消，已接纳的保存仍由根拥有。恢复失败也以 Toast 提示，模型发现错误保留各 Provider 的重试入口。

Writer请求与工具详情消费UI自有HistoryFailureDiagnostic，展示消息、分类、错误码、阶段、诊断字段和关联清理原因。UI不解析网络错误类型或执行重试，也不依赖Agents/ModelKit；数据由现有历史投影传入。

Writer云模型区提供深度思考开关，草稿默认false，编辑递增revision，通过既有保存/还原端口传递。UI仅保存布尔值，不解释Provider推理参数；保存后对新建/续作委托生效，当前执行不变。本地选择隐藏此云端选项。

Writer 请求详情依次展示本轮概览、本轮输入、本轮工具调用、本轮产出和调试日志。详情通过 WriterRecordsControlling.requestDetail 按稳定记录 ID 加载，概览展示轮次、操作、阶段、路径、重试、时间、可复制的请求 ID 和独立的模型、工具状态。委托来源集中展示于委托详情。前序和 Workspace 请求通过系统返回回到各自入口，工具来源链接只指向已验证的较早请求。下拉刷新更新在途记录，单页的读取与清日志互斥，刷新失败保留已显示数据。

输入优先使用本轮持久化的 user/tool 快照，其次是日志中的最后一组 user/tool，再回退到业务输入文本。工具反馈显示简短摘要并可展开原文；已匹配的工具来源提供跳转。工具目录来自本轮保存的定义，默认收起，区分空目录、未记录和读取失败。调用卡直接展示命令、目标、状态和错误，参数及结果默认收起。产出按存在性显示已保存的模型文本或文件路径，以及已有历史模型调用的宿主收尾状态和证据，均按需展开。

调试日志中的完整 Prompts 和生成指标默认收起。Prompts 与 Assistant 共用 HistoryPromptItems，支持应用消息、Chat Completions 和 Responses 的结构化呈现。生成指标使用当前调用的模型、参数、首 token、时长、结束原因、用量及失败信息，缺少的参数标为未记录。

Writer工作区列表和详情目标标题使用系统primary正文色，Writer图标独立使用紫色；颜色不从Label父级传递到整段目标文字。深浅模式和高对比度由系统语义正文色适配，编号徽章默认灰色、失败红色，状态标签保留独立语义配色。

Writer workspace records represent agent-owned workspaces; runtime delegation states are not task-level presentation fields. Delegation groups use local display ordinals, never UUID text. Internal delegateID remains available only in full evidence/export, while window/file controls use readable workspace_N and window_N references.

历史缩略图使用固定112×84预览容器持有异步加载任务，加载身份包含请求、媒体和重试次数；
占位、图片和失败状态的切换不替换任务所有者。临时图片已释放时显示“图片已释放”，读取或解码失败保留重试；取消不提交空白完成状态。新日志图片直接解码完整请求的Base64，内容是实际发给模型的图片，可能经过缩放；不依赖Camera缓存、相册或当前State。日志缺少字节或已清理时不回退缓存、相册或业务字段。读取不改变模型选图。

Assistant 对话详情和 Writer 请求详情提供单条日志清空按钮及确认，历史列表提供共享全库清空。删除成功后就地移除日志副本并隐藏删除按钮，Writer 的调试日志区显示「日志已清空」。Writer 的概览、已持久化输入、工具目录、工具调用/结果、模型正文和宿主收尾仍可查看。Writer 详情加载请求体用于 Prompts，工作区导出可读取请求体和响应体。列表不承载 Base64，HistoryRecordedImages 负责有界字节解码和缩略图引用。

历史详情只消费 UI 投影。Assistant 页可携带前台任务摘要；Writer 页只携带本侧消息轮次，解码时缺少 taskCompressions 表示空摘要列表，不要求 Writer 存储提供 Assistant 字段。消息身份、创建时间和轮次结构仍是必需数据。

WelcomeProviderView 提供可选 URL（空值使用 OpenAI）与必填 SecureField API key，两项均使用用户主动触发的系统 PasteButton。SettingsFormController.needsWelcome 仅在恢复成功且 Provider 列表为空时成立；saveWelcomeProvider 复用现有 URL/长度校验及设置保存事务，成功后发布 Provider 列表，失败保留输入和错误。保存时阻止重复提交、编辑和关闭；停止后不发布新 Provider。Welcome 创建共享 Provider 配置，模型在 Agent Brains 的 Assistant、Writer 和 Decision 子页选择。稍后设置不写持久化标记。

保存配置仅在 Assistant 启用云端时将其草稿 key/model 同步到选中 Provider；Assistant 为本地时保持 Provider 列表的独立凭据，Writer 单独选择云端不会被 Assistant 的空草稿覆盖。

Assistant 详情在实际删除成功后生成去日志的内存副本，保留业务信息，移除请求、图片来源与生成 meta，导出同一副本；无需通过二次读取才能确认已提交的删除。删除失败保留原详情并显示错误，忙态阻止重复提交。

子页从已提交的共享 Provider 列表选择各自模型。Assistant 可选本地 Gemma；Writer 需要云端原生工具，显示不可选本地项及独立深度思考。Decision 的 Provider 菜单同时含本地 D3 和云端，选本地时可配置云端备用并查看最近决策路径。主用和备用点击同一个保存按钮生效。首次选择本地须安装 D3。ProviderModelPicker 保留已选模型并展示发现失败和重试；发现任务由根控制器拥有，离页取消发现，已准入保存继续。删除 Provider 后 Assistant 回到本地，Writer 未配置，Decision 清除云端引用并保留本地偏好。下载和模型生命周期由业务层拥有。

Assistant 请求详情的 User Request / Assistant Response 使用完整业务文本、允许选择复制和纵向换行，不限制行数。User Request 可包含多来源输入的完整批次，数据由历史读取端提供；列表预览的长度限制不用于详情。

Assistant 历史仅呈现实际发起的模型请求。列表和详情可显示该请求采用的 enqueue/interrupt、来源、采集时间标记、决策路径及批次关联；discard 不产生历史条目。真实模型请求无正文且无工具调用时显示生成中、失败、取消、中断或结束无输出的具体状态；只有工具调用时保留完整调用信息。协调证据随导出和清理日志后的投影保留。
