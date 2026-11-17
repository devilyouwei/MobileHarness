# 多云端模型、HTML 呈现与持续语音感知

记录日期：2026-10-24。状态：❌ 多 Provider 管理已开始实施，WebKit功能已实现并通过自动化与模拟器验证，持续语音感知待实施；本文记录目标与验收要求，不代表当前实现。三项可独立交付，不预设优先级。

## 1. 多云端模型配置与选择

目标：用户可添加、保存多个云端模型配置，并在需要使用模型的位置选择配置。

本次细化：一个 HTTP 或 HTTPS URL 对应一个 provider；大模型设置页在加载模型上方展示单选列表，每项可编辑、删除，末项为添加。列表以可编辑名称为主、单行 URL 为辅；新增自动生成 Provider N 默认名称，新增与编辑采用 modal，输入 name/url/key 并保留粘贴；URL 可留空，确认时使用 OpenAI 官方 https://api.openai.com/v1 地址。弹窗取消丢弃独立草稿，确认后返回列表；配置含 Key 和所选模型，点击页面保存后应用到全局；删除当前项关闭云端，不自动改选。首批沿用 OpenAI 兼容协议。自动化与模拟器验证记录见 validation/Provider-Management.md；真实服务验收仍待完成。

- ❌ 配置包含可辨识名称、服务 URL、API Key，以及实际请求所需的模型标识；同一服务可保存不同模型配置。
- ❌ 支持新增、编辑、删除、列表展示与选择，重启后保留配置和有效选择。删除被引用配置时明确提示影响并要求重新选择，不静默切换。
- ❌ URL 与模型参数提供校验；鉴权、网络、模型不存在和协议不支持等失败明确展示。保存配置与连接验证分别反馈，不将保存成功视为服务可用。
- ❌ Key 安全保存、界面脱敏，不进入日志、历史、模型上下文或普通配置导出；编辑时支持保留或替换现有 Key。
- ❌ 请求启动时固定配置版本；编辑、切换不串用在途请求的 URL/Key，不自动重放失败请求。

边界：复用已有云端适配、提供者发现与选择基础，新增的是多个用户配置的持久管理和选择。首批协议、全局默认与各 Agent 覆盖关系、旧单配置迁移规则在实施设计时明确；不承诺任意 URL 自动兼容。

验收：保存至少两个不同 URL/Key 的配置，重启后仍可分别选择和完成真实请求；验证编辑、删除当前配置、无效 URL、错误 Key、断网和在途切换；检查敏感信息不泄露。真实服务验证使用用户授权配置，测试替身结果单独标注。

## 2. WebKit HTML 内容呈现组件

目标：提供可复用的 WebKit UI 组件，允许以 HTML 描述和呈现内容，支持图表、示意图等富内容表达。

- ✅ 接纳 HTML/CSS 内容并展示，支持用于绘图的受控 JavaScript；明确文本、图形、尺寸适配与滚动行为。
- ✅ 定义内容提交、更新、关闭及加载失败的接口；按展示实例和版本隔离，迟到回调不能覆盖新内容。
- ✅ 明确脚本、外部网络、链接跳转与资源加载策略；默认不向 HTML 暴露 Key、原生对象或设备控制权限。原生交互桥接如有需要，必须另行定义窄接口与授权。
- ✅ 限制内容大小、更新积压及加载时间；超限、脚本失败、渲染进程退出给出可见错误与恢复入口，关闭后清理任务和脚本回调。

职责：UI 拥有中立组件、呈现状态和回执；Agent 决定表达内容，业务呈现通过 Actions/Gateway。UI 不依赖 Agent，不解释业务执行权限。使用通用Window.web插槽和Actions内部独立编辑协议，不以组件加载完成宣称图表语义正确。

验收范围：在原生 UI 展示文本、静态示意图和脚本图表；覆盖长内容、连续更新、关闭重开、导航/前后台、非法内容、外链与越权桥接；验证渲染失败可见且旧回调隔离。

## 3. 持续聆听与打断判断的 Speech Perception Agent

目标：用户启用后，SpeechPerception 在前台会话持续感知语音，在助手思考、合成和播报期间也能判断用户是否要打断，并在确认后及时交接新一轮输入。

现状：已有常驻聆听策略、VAD/ASR 和半双工恢复；回复占用期间抑制新句接纳，barge-in 尚未实现，见 [当前语音设计](../../../MobileHarness/Agents/SpeechPerception/README.md)。本项需要扩展现有角色，不新增平行语音实现。

- ❌ 显式启用/撤销持续聆听；页面切换不销毁会话，权限拒绝、音频路由变化、系统中断和退出都有明确状态。
- ❌ 回复期间持续提供打断判断所需的音频；区分用户发言、短噪声、环境人声和助手回声，不能仅因 VAD 有声便一律中断。
- ❌ 定义疑似打断、确认打断、继续聆听和新句提交的状态与证据；是否需要语义模型、判断阈值和延迟目标由后续设计及实测确定。
- ❌ 确认打断后，经授权执行取消当前回复/合成/播放并加入清理，保留用户语句开头；旧代输出不得继续播放或重复提交。已发生的设备效果不能被伪装成撤销成功。
- ❌ 会话所有者独立于页面；音频、识别和判断队列有界、溢出显式失败，撤销后不自动重新启用。区分打断回复与关闭 Task，明确失败及恢复语义。

边界：SpeechPerception 拥有判断策略，PlatformKit 提供原生采集能力，ModelKit 提供推理能力，Actions 执行真实采集/停止/播放效果，Gateway 保留授权与取消边界。本项不默认包含 iOS 后台常开麦克风；进入后台按公开平台能力与现有安全生命周期处理。

验收：真机覆盖静默待命、多轮长时运行、思考/合成/播放中的插话、连续打断、回声、噪声、旁人说话、撤销与重启、路由/权限/系统中断；记录误打断率、漏检率、确认到停止的延迟、句首保留、内存与热状态。量化门槛在实现前确定，自动化替身不能代替声学实测。

WebKit 条目的详细范围、跨模块设计和实施验收见 [WebKit Actions 计划](../../completed/WebKit-Actions-Plan.md)。它覆盖远程浏览截图与独立模型驱动的本地多文件绘图，其他模型配置/语音需求保留各自范围。

## 2026-11-05 Settings 首页英文命名和入口顺序

Settings 首页保留原有分区顺序及模型入口顺序，界面标题/分区/入口/蓝牙状态摘要全部英文。User 区依次为 Album、My Assistant、My Writer、Memory；Memory仍为静态项，导航身份不变。除蓝牙外设改为标准蓝牙形状标志，其余图标保持。没有合适系统蓝牙标志时用同文件私有SwiftUI Shape绘制，避免缺失符号或引入资源目录/第三方库。此次不扩展为各子页/历史内容的全面翻译。

修改UI/Settings/SettingsView与既有蓝牙状态显示投影，状态转换及业务不变；同步Settings README、相关既有状态断言。使用原生模拟器验证英文入口、顺序、图标和原有导航；执行check.sh/build-ios.sh，真机安装另行记录。

本节实现及Settings技术README已对齐；检查脚本/四目标构建、原生模拟器名称顺序与截图核对完成。原生通用套件日志缺口及真机未安装分别记录于docs/validation/Provider-Management.md。

## Agent Brains 总页与独立配置

- Settings 的 Agent Brains 总页依次显示 Cloud Providers、Assistant/Writer/Decision 子页入口及本地模型下载。共用 Provider 与模型发现缓存，角色独立选择。旧 Decision 导航进入同一个子页；Memory 延用 Assistant。Gemma 4 E2B 和 D3 在同一个下载区使用同一下载源，按模型 ID 分别操作，复用既有下载容量与生命周期。
- UI/Settings 子页持有独立草稿，显示已提交的 Provider，返回时放弃该子页未保存的编辑。总页 Provider 草稿在进入子页时不提交。角色列表整行可点，标题与状态使用系统主、次正文色。SettingsFormController 在现有私有设置请求上以已保存配置合并当前页改动，单个保存门阻止竞争，成功后发布已提交状态；失败保留页面草稿。删除 Provider 时 Assistant 回到本地，Writer 未配置，Decision 清除引用并保留本地模式。Root 更新原生路径与可访问性标识。
- Assistant 使用本地 Gemma 或云端。Writer 云端要求原生工具，保留深度思考和旧无 Provider 状态。Decision 主 Provider 选择包含本地 D3 或云端，选本地可单独选云端备用。首次选 D3 时校验安装；既有本地选择在模型缺失时继续保留。最近路径在收到分类状态前显示尚无记录。下载不触发自动选择。
- Actions Provider 设置文档新增可选 Decision 本地模式字段。旧文档缺字段时从下载设置读取原值，不因读取而重写；首次保存将有效值写入同一设置事务，主用、备用随之原子提交。下载设置中的旧字段仅为迁移读取保留，新下载设置写入保留旧值。移除原资源保存通道的 Decision 安装错误映射，安装校验由 Provider 保存事务返回。Actions 通过 App 向 Assistant 输入分类交付冻结的模式和可选云端模型工厂，分类过程中沿用该快照。设置提交期间的新分类读取上一次成功提交的快照，保存失败时继续使用该快照。D3 不可用时使用已保存备用，否则保守入队。非 Assistant 配置变更不重配 Assistant 模型。
- 实现后同步 UI、Root、Provider、模型资源与总体设计。验收覆盖导航、独立提交和回滚、模型发现、迁移、删除、分类回退以及两种模型的独立下载操作。运行全量检查及 iOS 构建，原生导航与真机/真实模型证据分开记录。

## 2026-11-15 模型设置命名与双语呈现

意图：Settings 入口及总页标题由 Agent Brains 改为 Agent Models（智能体模型），入口使用 SF Symbols `atom`；总页 Agents 分区改为 Models（模型），依次保留 Assistant（助手）、Writer（创作助手）、Decision（决策）三项。

涉及 `UI/Settings/SettingsView.swift`、`UI/Shared/Localizable.xcstrings` 和 `Actions/System/Provider/SettingsProviderAdapter.swift`：同步下载说明与安装校验提示中的页面名称，中英文均指向对应语言的页面标题。只调整呈现，不改变角色身份、导航标识、保存事务、模型选择或下载流程。同步 Settings、Shared、Root、UI、Provider、ModelResources 及总体技术 README 中的当前页面名称；跨模块接口与所有权不变。

验证：核对中英文目录键、三个模型顺序、原子符号与旧文案引用，运行 `scripts/check.sh`、完整 Xcode 可用时运行 `scripts/build-ios.sh`；自动化与原生界面验收分别记录。

合并远程 D3 Lite 支持时，保留远程 Edge/Lite 模型身份、资源与选择流程，同时保留本节 Agent Models 命名与 atom 图标。冲突涉及 Settings、ModelResources 及总体技术 README；下载与安装提示继续采用中英文新页面名，模型选择接口不回退。

## 2026-11-15 单一模型选择与 Decision 入队兜底

需求：三个 Agent Models 子页统一采用 Provider → Model 两级选择；Provider 包括 Local 和已保存云端服务，选云端后发现其模型，再选择 Model。Assistant/Writer 本地候选为 Gemma 4 E2B，Decision 为 D3 Edge/Lite。未安装候选允许点击并明确提示先下载，不改变草稿；保存端再次按制品身份校验，失败不提交。Writer 增加显式本地模式字段，区分旧未配置值；旧配置默认未启用 Writer 本地。现有 Gemma 的 Writer 原生工具能力限制继续明确失败，不增加模型能力或隐式切换。

Decision 仅执行所选模型，本地和云端互斥；移除 UI 的 Cloud fallback 及运行时云端备用路径。旧文档本地模式下残留云端选择不再执行；保存本地选择清空云端引用。配置失败、资源不可用、准备中、超时、无效输出及推理失败均以 enqueue 兜底，并显示中英文错误 Toast；取消/停止不显示错误 Toast。保留原始失败诊断、输入归属与后置采纳保护。本地准备工作仍归根拥有，超时取消并加入实际工作后才释放；每个引擎至多一个在途 worker，清理未结束时拒绝新调用，无 UI 生命周期转移。

修改范围：AssistantInputDecision 的独占选择和类型化失败；AgentRuntime 将有效失败投影到已有 Toast/日志；ActionsBusinessAssembly 只交付选中的模型工厂；ProviderSettingsService/Store/Contracts 与 ApplicationControl/UI 适配传递 writerUsesLocal 并校验安装；SettingsState/FormController/View 统一两级选择与本地错误；Shared String Catalog 增加中英文文案；RuntimeLog 移除已无意义的 localFallback 展示字段。同步 Assistant、Agents、Provider、Contracts、Actions、Settings、Shared、RuntimeLog 和整体设计的真实契约，保留历史验证记录。

验证覆盖本地失败不调用云端、云端失败不调用本地、取消不提示、明确失败提示及入队、Edge/Lite 成功、Writer 本地保存恢复与未配置区别、未安装资源拒绝及回滚、Provider 选择和模型发现的迟到结果围栏。运行 check.sh、build-ios.sh；自动化替身与真实模型/原生界面验收分别记录。保留已有未提交改动，不新增目录。

呈现细化：现有 offerToast 默认显示在首页字幕区，可能被正在显示的助手回复遮住。为确保 Decision 错误实际以 Toast 展示，HomeNoticeState 增加通用错误呈现位置参数（默认保留字幕行为），Decision 使用 toast 位置；Root 复用已有全局 transientToast 覆盖层并按 tone 显示错误图标。沿用单槽替换、去重、8 秒到期和根停止清理，不增加 Task 或独立队列。同步 UI/Conversation、Root 技术文档，并测试错误在全局 Toast 中呈现及清理。

单一模型执行、三页 Provider/Model 选择、Writer 本地模式持久化、未下载校验及中英文全局错误 Toast 已实现。构建/专项回归与全量检查限制见 [验证记录](../../validation/Provider-Management.md#selected-model-execution-and-bilingual-settings-2026-11-15)；实际模型与原生界面/真机验收未执行。

## 2026-11-15 本地 Gemma OpenAI 风格工具协议

意图：在既有 ModelKitGemma4 目录实现 OpenAI 中立 tools/function、assistant.toolCalls、tool_call_id 的 Gemma 4 原生模板适配，不引入 HTTP 服务或云端调用。声明、参数、结果遵循 Google 官方 Gemma 4 工具标记；调用 ID 由适配器生成，结果按 ID 映射回函数名。工具请求完整保留 system、定义和调用/结果配对，按真实 tokenizer 计费；超出 iOS 1024/macOS 4096 窗口明确失败，不截断协议或回退模型。纯文本诊断路径沿用原有裁剪契约。

Gemma4Chat 负责能力声明、请求校验、工具输出有界缓冲、完成校验和中立事件；GemmaLanguageEngine 负责原始模板编码、在工具响应起始标记停止并维持取消/释放语义；同目录工具适配器负责嵌套对象/数组/字符串/数值解析、拒绝重复键、未知函数、无效/截断输出及 required 工具违约。完整生成成功并校验全部调用后才发布工具事件；错误不执行工具。工具结果仍由调用方执行后回传，ModelKit 不拥有业务执行。更新 Writer/UI 双语能力说明以及 ModelKit/LLM/Gemma4/Writer 和总体设计。新增无权重协议、往返、失败和上下文回归；真实权重与设备验收单独记录。运行 check.sh、build-ios.sh。

集成核对补充：ModelContainer.ConfiguredChat 的固定配置包装器不能再以 configuration != nil 推断工具能力。由 ModelScope 按该包装器冻结的配置解析轻量 capability（本地 get(load:false)，云端沿既有缓存），异步转发 supportsToolCalls/supportsImages；不得借用会变化的 Assistant 默认选择。Tests/ModelKitDefaultsTests 验证本地、云端及独立根的实际能力、固定本地选择不随默认配置变化，并保留无权重加载断言。同步 ModelKit 和默认装配测试文档。

本地工具模板、解析/结果回传、固定配置能力透传和双语说明已实现；专项回归与 iOS 构建通过。真实权重工具选择质量及设备验收待执行；全量测试的失败与未完成套件保留于 [验证记录](../../validation/Provider-Management.md#local-gemma-native-tools-2026-11-15)。

## 2026-11-15 模型原名与用途标签

Agent Models 总页三分区依次改为 Cloud Providers & Models（云端服务与模型）、Agent Models（智能体模型）、Local Models（本地模型）。Resources/Models/model-catalog.json 的显示名统一为 Gemma 4 E2B、D3 Edge、D3 Lite；UI/Settings 的选择摘要、候选和安装提示同步使用原名，移除模型名称中的 Local Chat、Decision 后缀。保留模型 ID、制品目录、版本、下载与选择语义。

ModelResourceSections 的本地模型条目在名称下方显示用途胶囊：Gemma 为蓝色 Chat（对话），D3 Edge/Lite 为橙色 Decision（决策）。文字标签同时表达用途，不仅靠颜色；标签使用可缩放字体并保留模型标题换行空间。仅涉及显示与现有模型 ID 的 UI 分类，不引入业务依赖或新目录。同步 Settings、Shared、模型资源 README 及相关当前设计；验证中英文名称、分区、标签与布局，执行 check.sh/build-ios.sh，记录原生检查与自动化结果。

模型原名、三分区及双色中英文用途标签已实现，构建产物核对和四目标构建通过；新版已安装到 iPhone 17 Pro，手机锁定导致自动启动未成功。原生视觉验收限制、全量测试失败及运行时通过结果见 [验证记录](../../validation/Provider-Management.md#canonical-model-names-and-purpose-badges-2026-11-15)。

## 2026-11-16 首页 Decision 预加载

目标：首页前台准备流程包含当前已配置的本地 Decision 模型，避免首次输入才冷启动。Agents 从已保存的 Decision 配置提供只读模型 ID；App Composition 将其接到 ModelKit 的按本地模型选择生成的准备步骤，追加到现有 language/recognition/synthesis/voiceActivity（及按需 vision）队列。支持 d3-edge、d3-lite、gemma4-e2b、apple-system；云端或无独立本地选择返回 nil，不加载本地资源。ModelKit 负责公开模型 ID 到资源的映射、真实 status/warmup 及 loading 回报，不拥有角色配置。准备保持串行、取消加入、交互时延后、完成后统一复查；未知 ID/缺资源/配置读取失败明确失败。更新 Agents/ModelKit/App Composition 及总体 README。测试未选择、各本地 ID、未知 ID、配置读取失败和停止后的拒绝，运行 check.sh/build-ios.sh；不宣称云端连接或物理设备实测通过。

Decision 首页预加载已实现，定向测试与 iOS 五目标构建通过。验证与真实模型/设备限制见 [Decision 首页预加载](../../validation/Decision-Startup-Preparation.md)。
