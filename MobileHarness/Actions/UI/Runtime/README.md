# UI/Runtime — 业务能力与执行

## 职责与关系

运行异常分类属于 ApplicationControl，本目录校验已分类值并呈现；蓝牙展示只更新事实，不连接或控制设备。活动观察与频谱状态由根所有者管理，停止取消并加入观察；频谱句柄以根／采集代际隔离。

本目录由所属域目录绑定；Agent 调用接受标准 FunctionInput，上游 Gateway 保持调用权限、通用调度与资源仲裁。Actions container 内函数组合直接调用类型化 Action 接口，不经 Gateway 或通信。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [BluetoothStatusActions.swift](BluetoothStatusActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [MicrophoneSpectrumPresentation.swift](MicrophoneSpectrumPresentation.swift) | 频谱测量校验、平滑与根／采集代际接纳 |
| [RuntimeDiagnosticsActions.swift](RuntimeDiagnosticsActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [IslandActions.swift](IslandActions.swift) | 通用Action、纯参数解析、显式Module、发布/图片接口与执行服务 |
| [IslandDomainPresentation.swift](IslandDomainPresentation.swift) | 观察已有领域事实并转换为中立IslandContent |
| [RuntimeIssue.swift](RuntimeIssue.swift) | 已分类运行异常的有界呈现值 |
| [RuntimePresentationCapabilities.swift](RuntimePresentationCapabilities.swift) | 异常、蓝牙状态的呈现契约 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)

## Execution ownership and lifecycle

ActionActivityWorkflow and ActionActivityPresentation live in Agents/Support because they interpret passive role/Task evidence. Callable RuntimePresentation remains in Actions, validates business/session state and presents already-classified facts. MicrophoneSpectrumPresentation implements the neutral SpectrumPresenting interface with UUID handles.

## Island 呈现

IslandModule显式注册UI.Island.present/update/end/setPresentation；前三项内部Tool，setPresentation提供Action/Tool。IslandCommand提供字符串解析和类型化构造，两者共用字段组合／内容校验。IslandActions.execute是共同执行入口，IslandPresentationService消费可信IslandActionContext并使用UI端口，不参与布局/动画。外部适配仅解析参数、由invocation派生身份、把IslandReceipt序列化；内部调用使用装配绑定的IslandActionCalling端口，不构造FunctionInvocation、不经Gateway。setPresentation接受compact/expanded，expanded要求detail，large/custom/animation/width/height拒绝。回执submitted/localStatus/systemStatus区分接纳、前台实际完成和系统状态；系统禁用/失败不阻塞前台或判定业务失败。

IslandDomainPresenting只提供available/generation、固定camera/voice/bluetooth领域的绑定Action端口、错误报告及32频带接口。IslandDomainPresentation同步读取既有Camera/Voice/蓝牙事实并注册Observation，随后在跟踪范围外异步调用IslandActions.execute的绑定入口；不采设备、不观察自身Action日志。每领域持有稳定活动UUID、递增revision和一个最新待发命令；相同内容不重复调用，失败以同一版本重投，新内容使用更高版本替换待发命令。每次根generation变化重新绑定端口与活动身份，旧端口拒绝跨代写入。

观察只有一个可取消加入的worker和bufferingNewest(1)唤醒槽，待发命令上限为三个固定领域。一个可替换加入的计时器合并蓝牙3秒临时提示过期与500ms失败重试；异步执行期间到期的事项立即唤醒补处理，根不可用时不保留轮询计时。停止关闭准入、取消／加入worker和计时器，再经绑定Action结束本领域活动；不撤下Agent活动。错误保留在UI的Island事实中。频谱使用专用数据接口，不推进活动revision或调用ActivityKit。

领域提交通用语义优先级：拍摄critical、录像attention、待处置/蓝牙临时/说话high、Task/聆听normal、思考low、稳定蓝牙background；排序策略由UI组件拥有。任务详情与阶段由拥有任务的 Agent 发布，开始展开、同阶段进度不重开、结束撤下。普通相机/语音/连接活动不提供详情，不能被setPresentation强行展开。UI将有详情的任务与无详情的实时状态独立选择；顶部按状态优先级切换语音、相机、蓝牙等内容，下方持续显示任务目标及图标，直到任务更新或结束。任务收起偏好不受顶部切换影响，领域无需组合或复制两路内容。系统与App共用中立内容，平台不同的动画/显示能力由UI组件处理。

任务状态本地化及目标详情由 Agent 的呈现适配负责。领域内容不携带导航目的地或跳转按钮；系统岛整体点击固定唤回App当前页面，不自动打开Camera/蓝牙/记录；停止/取消/保存继续由Camera窗口执行。liveActivity=false仅关闭该内容的系统投影，不关闭App内显示。

IslandContent使用primary/secondary通用指标和detail(text,thumbnail)，UI只解码当前字段，不转换旧快照。IslandThumbnailPresenting提供注册/释放的窄类型化端口，owner与活动提交者一致；Action内容只传注册引用，不能读取任意文件或URL。有效详情自动展开，setPresentation针对指定活动改变偏好；状态/详情各自的优先级选择和逐活动收起记忆由UI实现。本目录的相机、语音和连接领域无详情，不自动展开。图标动效预设属于内容，shell animation/width/height参数仍拒绝。

聆听域投影在连续listening阶段保持一个startedAt，退出阶段或根换代清除，下次聆听重计。背景、频谱/其他领域更新和优先级遮挡不改变起点。提交secondary.elapsed，不维护逐秒计数；通用计时排版归UI组件。Action JSON的elapsed.startedAt遵循默认Swift Codable Date，即2001-01-01 UTC起的秒数，拒绝非有限/无效日期。


IslandActions归并通用Action声明、纯IslandCommand解析、显式IslandModule绑定、IslandControlCapability/IslandDomainPresenting/IslandThumbnailPresenting端口和IslandPresentationService执行；IslandDomainPresentation只拥有语音/相机/蓝牙领域投影与观察生命周期。IslandSize仅compact/expanded，已删除IslandMotion和不使用的宽高/动效字段；旧large/custom/width/height/animation请求在参数入口明确拒绝，不再进入执行逻辑，也不在Action参数目录中展示。

Writer 和 Assistant 前台任务岛由各自 Agent 执行所有者调用注册的 UI.Island.present/end 内部展示工具，Gateway 校验生产者身份；Writer 的业务阶段、紫色身份和详情由 Writer 域拥有，Assistant 仅处理自身前台 Skill 任务。终态撤下对应活动。模型的 Assistant XML Action 协议不变，内部展示不进入模型目录。本目录不再从 Task 日志投影任何任务岛，也不生成 domain.task/domain.writer 活动。语音、相机与连接继续使用各自领域槽。UI 统一仲裁顶部实时状态与任务详情，Actions 不组合两路内容或编排动画。

内容发布、更新和结束共用UI的owner/revision校验及幂等结束。内部领域端口的owner和generation由执行服务绑定，模型参数不能指定；内部setPresentation只能修改本领域活动。外部setPresentation保留Skill授权的共享展开／收起能力，这一可信呈现范围不授予修改／结束其他owner内容的权限。UI手势、导航遮挡、根生命周期、布局与动画回执仍由组件内部处理。
