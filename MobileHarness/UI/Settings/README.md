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

✅ 各子容器、呈现协议及请求接口与所属状态同文件；导航由 UI 根提供。音频检测属于 Diagnostics，本目录仅嵌入其公开 Section，不复制状态或控制实现。

## 表单与资源

✅ Provider 草稿包含地址、模型和密钥，不写入模型历史／用户日志。发现、恢复、保存保留草稿 revision，迟到结果不覆盖新输入；页面离开取消发现任务。根停止清除敏感草稿。

资源界面按目录 ID 展示识别、合成、语言和视觉，接受宿主提供的安装／下载／删除／取消及偏好事实；刷新保留 generation。下载不自动开启自定义语音，资源资格由宿主判定。

## 设备展示

BluetoothSettingsState 分开呈现可用性、发现、连接、传输问题、控制资格及恢复阶段。点击未连接设备提交连接意图，已连接设备打开本地详情；滑杆释放／停止提交实际停止意图。连接事实不代表物理动作验证。

设备子容器在 UI start 前只暂存一个最新快照，start 应用 UI 值但不查询设备；停止清除待应用值。真正连接、恢复、控制 worker 和清理属于外部能力拥有者。

## 历史值、分页与导航

AgentRecordsView 是注入的记录页面入口，当前 Assistant 提供实际会话记录。ConversationHistoryView 不构造业务总结或持久化结果；只有原始 modelRequests 投影为请求行，不伪造续轮／任务。

Task 压缩行以实际 historyTaskID、input/request 来源对及 historyOrder 校验，在原请求位置展示；展开源记录独立分页。不同 Task 的 source、request-time task 快照和 live execution 状态保持区别。缺失证据不补造。

页面保留20项游标分页、ticket／generation、首次成功加载门和显式重试。最多16个 Task 页读取，超额显式拒绝。取消只释放匹配 ticket；完成 revision 唤醒被取消的可见 footer，不由开始读取自行取消任务。

下拉刷新取消并加入时间线与 Task 读取后重置分页，刷新失败保留已有内容；从详情返回不重载成功页或重建列表，保留展开和滚动位置。不同会话以稳定 ID 隔离。请求详情使用一个选择值和一个 navigationDestination，重复点击不累加导航。

## 历史展示与导出

Task／ReACT 标签、状态、来源数量及分层缩进分别表达真实证据；详情保留原始输入、模型请求、执行、元数据和 Functions/Skills。结构化 Function Catalog 只解析记录时的 schema，一次解析并保留错误与原 JSON，不回退为当前注册表或虚构空结果。

Function Catalog 为独立平铺 Form 行，展开状态为页面局部值，避免嵌套交互行接管点击。Token 用量只显示已报告的值，包括可选缓存读写；零与缺失不同。

JSON 分享延迟编码实际展示的 Codable 值，保留原始 requestJSON；prettyPrinted/sortedKeys、默认日期编码，最大32MiB。取消／编码错误显式传播，不创建临时仓库数据或空导出。

历史图片仅解析结构化引用，按身份去重并限制展示数量。全屏检查器使用共享 RetainedFullScreenCover 保留下层首页；页面图片解码／读取仍随离开取消。

## 接纳、失败与待验收

✅ 子容器统一创建状态，业务只读协议＋类型化提交；根停止后拒绝更新，后台允许保留事实。设置 revision、资源 generation、分页 ticket 独立于根接纳。

❌ 更多 Agent 记录 schema、历史页面重设计、交互返回／滚动保持、目录点按、分享接收端及蓝牙物理行为仍需单独验收，自动化状态测试不代替真机。

[UI 根](../README.md) · [音频检测](../Diagnostics/README.md)

✅ 历史消息读取有页面所有者、取消／身份校验与加入；目录在通用执行器解析，按原JSON身份缓存，时间线仅随加载／分页重建并预分组。资源下载源编辑提交窄控制接口，页面不轮询自动保存；外部唯一工作流合并初始恢复并拥有防抖、停止与错误上报。

历史详情读取的容量约束：一个实际读取与一个最新候选，取消清除候选并取消实际读取；候选替换不创建等待任务链，实际读取完成后才接纳下一项。

✅ 已实现：devices呈现Action维护独立连接摘要，设置页展示该状态；详细设备／机械臂控制资格仍消费原真实状态，不由显示摘要解锁设备。


## Direct container contract

UI-owned typed request/reply capabilities have one consumer and at most 64 outstanding requests, including accepted work. Acceptance does not complete a request. Cancellation, consumer exit, root invalidation and late replies are generation-fenced. Foundation dependencies remain empty. Current cross-module ownership is defined by the [overall design](../../README.md).

## Agent-owned UI inputs

✅ Settings, resource, device and history subcontainers own their typed request/reply sources and UI generations. Business consumers are constructor-injected owners outside UI; pages and local interaction facades submit through these sources. UI contains no business event subscriber or Gateway dependency. Actual query/effect failure remains a failed receipt, with late completion fenced by generation.

## 直连链路当前契约

✅ 未提交表单和页面状态留 UI，业务提交、结果与运行事实的呈现归 Actions。

## Provider 表单控制

SettingsFormController 只拥有草稿规范化、默认选项、请求忙态和迟到结果围栏；经 SettingsOperating 提交 UI 自有请求，不导入业务或设备模块，不执行凭据持久化、模型切换或实际 Provider 发现。根持有控制器，页面退出取消发现并推进 revision。

## 多 Provider 管理

✅ 沿用私有设置事务传递至多 32 个 URL 唯一的 provider；当前配置与其余配置一起保存。UI 在加载模型上方提供单选、编辑、删除和末行添加，删除当前项关闭云端并要求重新选择。保存提交后生效，Key 保持钥匙串存储，旧单配置恢复为首项。

✅ Provider 名称通过私有配置链路保存，旧数据以 URL 主机名补齐。新增/编辑采用独立 modal 草稿（name/url/key），默认生成未占用的 Provider N 名称；取消不修改选择和凭据，确认校验 URL 唯一性与名称。列表名称为主、URL 单行省略为辅，保留三字段粘贴和 Key 脱敏。

✅ ProviderEditorDraft 同时接纳 HTTP 与 HTTPS（域名或 IP，可带端口和路径）；保留名称、URL 唯一性、凭据长度和容量校验，错误提示不再要求仅 HTTPS。实际网络策略见 [Config](../../../Config/README.md)。

Implemented: Provider URL input is optional. Blank/whitespace input resolves to https://api.openai.com/v1 on modal confirmation, sharing the same URL identity as an explicit official endpoint. Keep name/key, duplicate checks, and nonempty HTTP/HTTPS validation. Cover default resolution and duplicate default providers.

## 用户板块入口

✅ SettingsView 用户板块依次呈现“记忆”“相册”“Agent 记录”。记忆为无点击行为的静态 Label；相册进入独立照片管理页面，Agent 记录继续使用现有导航。

## 基础相册实施契约

✅ 启用相册导航，时间倒序网格每页40项、详情缩放、最多20张系统选择器导入、单张导出及确认删除。记忆保留静态项。长操作由根持有，页面退出不取消已接纳变更。

删除回执区分逻辑删除成功与文件清理问题；逻辑提交后即从当前UI列表移除，清理失败明确提示并保留恢复状态。

详情展示采用原生 Image I/O 最长边4096像素的按需显示图以限制解码内存，UIScrollView提供1～5倍缩放；导出始终读取原片文件，不导出显示图。

## Container 上下文

✅ UIAlbumContainer.ContextSnapshot 提供内容状态、当前已加载数量、后续页标记及importing/exporting/deleting操作。导航公开相册详情对象、照片选择器／删除确认框，以及历史列表、对话及轮次详情。局部内容变化只能更新当前确认位置；过期代际拒绝。离页不取消根拥有的相册变更。
