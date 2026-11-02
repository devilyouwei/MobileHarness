# UI/Runtime — 业务能力与执行

## 职责与关系

运行异常分类属于 ApplicationControl，本目录校验已分类值并呈现；蓝牙展示只更新事实，不连接或控制设备。活动观察与频谱状态由根所有者管理，停止取消并加入观察；频谱句柄以根／采集代际隔离。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

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

IslandModule显式注册UI.Island.present/update/end/setPresentation；前三项内部Tool，setPresentation提供Action/Tool。IslandCommand纯校验，IslandPresentationService只派生owner并使用UI端口，不参与布局/动画。setPresentation接受compact/expanded，expanded要求detail，large/custom/animation/width/height拒绝。回执submitted/localStatus/systemStatus区分接纳、前台实际完成和系统状态；系统禁用/失败不阻塞前台或判定业务失败。

IslandDomainPresenting窄协议发布中立内容、错误和实际32频带，只读available/generation。IslandDomainPresentation消费既有蓝牙/Task/Camera/Voice事实，一个bufferingNewest(1)唤醒槽及一个可替换加入的蓝牙计时器；不采设备、不观察自身Action日志。频带独立更新，不推进活动revision或调用ActivityKit。根停机加入观察/计时器。

优先级为拍摄100、录像90、Task85、待处置80、蓝牙临时70、说话65、聆听60、思考55、稳定蓝牙0。只有Task提供IslandDetail(text:任务目标文字)及阶段身份，详情不包含进度状态或业务按钮；开始展开、同阶段进度不重开、结束撤下。普通相机/语音/连接活动不提供详情，不能被setPresentation强行展开。UI将有详情的任务与无详情的实时状态独立选择；顶部按状态优先级切换语音、相机、蓝牙等内容，下方持续显示任务目标及图标，直到任务更新或结束。任务收起偏好不受顶部切换影响，领域无需组合或复制两路内容。系统与App共用中立内容，平台不同的动画/显示能力由UI组件处理。

Task currentTaskStatus仍按实际来源本地化作为状态摘要；detail只消费目标文字。领域内容不携带导航目的地或跳转按钮；系统岛整体点击固定唤回App当前页面，不自动打开Camera/蓝牙/记录；停止/取消/保存继续由Camera窗口执行。liveActivity=false仅关闭该内容的系统投影，不关闭App内显示。

IslandContent使用primary/secondary通用指标和detail(text,thumbnail)，旧字段只在UI解码边界迁移。IslandThumbnailPresenting提供注册/释放的窄类型化端口，owner与活动提交者一致；Action内容只传注册引用，不能读取任意文件或URL。有效详情自动展开，setPresentation针对指定活动改变偏好；状态/详情各自的优先级选择和逐活动收起记忆由UI实现。Task仅传目标文字与primary，其他现有领域无详情，不自动展开。图标动效预设属于内容，shell animation/width/height参数仍拒绝。

聆听域投影在连续listening阶段保持一个startedAt，退出阶段或根换代清除，下次聆听重计。背景、频谱/其他领域更新和优先级遮挡不改变起点。提交secondary.elapsed，不维护逐秒计数；通用计时排版归UI组件。Action JSON的elapsed.startedAt遵循默认Swift Codable Date，即2001-01-01 UTC起的秒数，拒绝非有限/无效日期。


IslandActions归并通用Action声明、纯IslandCommand解析、显式IslandModule绑定、IslandControlCapability/IslandDomainPresenting/IslandThumbnailPresenting端口和IslandPresentationService执行；IslandDomainPresentation只拥有语音/任务/相机/蓝牙领域投影与观察生命周期。IslandSize仅compact/expanded，已删除IslandMotion和不使用的宽高/动效字段；旧large/custom/width/height/animation请求在参数入口明确拒绝，不再进入执行逻辑，也不在Action参数目录中展示。
