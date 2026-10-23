# Conversation — 首页与运行记录呈现

✅ 按压手势用 GestureState 保留本地按压状态，状态变化才提交 press(true/false)，移动不重复发起准备 Action；抬起、取消及页面离开自动复位。交互不可用时不提交新请求，原生取消仍归根生命周期。长按触发、原接纳容量、错误回执和业务判断保持；真机控制错误仍须独立定位。

✅ ConversationState 单独拥有 replyWaitingRequest；首个输出、匹配清理、新回复、停止聆听、恢复聆听和失活解除等待，旧请求不能清除新请求。模型准备 checking／ready 不清除请求等待。

✅ HomeModelPreparation 只在 failed 提供重试资格；移除 cancelled 用户状态、消息文案及手动取消端口。首页恢复提示仅含重试按钮，加载时没有文字／按钮；真实加载眼睛仍由表达 Action 接纳。

## 职责与接口

UIHomeContainer 唯一创建 ConversationState、ActionActivityState、HomeEffectsWorkflow 和 ConversationExpressionPresentation，向业务分别暴露 ConversationPresenting、ActivityPresenting、HomeEffectsPresenting、ExpressionPresenting。

上游业务集成提交经会话／轮次验证的 UI 值；本目录消费 Components 的原生呈现，向上游转发聆听／重试意图及表情回执。没有 Signal 订阅、模型调用、设备控制或持久化。

## 文件与内部关系

| 文件 | 职责 |
| --- | --- |
| UIHomeContainer.swift | 子容器装配、共享根接纳及失活／停止 |
| ConversationState.swift | 会话值、字幕几何、呈现协议与表情事务 |
| ConversationView.swift | 首页和启动界面，隔离频谱、表情与字幕观察 |
| HomeBluetoothIndicator.swift | 安全区布局估算、灵动岛同色延展、蓝牙图层与动画生命周期 |
| ActionActivityState.swift | Action／Task／Agent 日志值、异常、过滤及有界展示状态 |
| ActionActivityView.swift | 运行摘要、日志面板和详情 |
| HomeEffectsWorkflow.swift | Notice／装饰光／回复清理及其到期任务 |

✅ 日志值及异常呈现接口归 ActionActivityState，效果／表情协议与实现同文件；导航由 UI 根提供。首页消费真实状态，不包含另行构造的模拟记录或视觉演示页面。

## 字幕、表情与交互

✅ 半秒长按提交一次聆听切换；零距离拖动只提供按压和归一化光源位置，不直接打开设备。辅助功能激活使用相同控制端口。停止意图可打断回复；实际聆听和播放状态由外部执行者投影。

✅ 业务确认一轮结束并恢复聆听时，HomeEffectsWorkflow.replyDidFinish 同步清除已定稿用户字幕并重置定稿标记，回复沿用既有350ms淡出。无文字回复也清理已完成用户字幕；下一轮未定稿转写不清除，旧回复到期任务不能清理新输入。

识别与回复分别占位：新的已接纳识别轮次清除前轮两段字幕，定稿的用户文本移到眼睛上方，回复期间保留两段字幕；回到聆听后的展示清理由外部完成策略触发。consent-off 清除字幕；普通生命周期暂停使旧 scope 失效。视图不推断 ASR 或播放完成。

ConversationCaptionLayout 分别计算固定任务行与移动字幕；仅活动的前台任务展示一行目标，定稿字幕与任务保留间距。用户字幕的位置只随定稿边界动画，任务出现不使用会造成重叠的间距补间。Components 在显示边界保留最新320个完整 Characters。

表情基态只提交状态；有限表演拥有独立身份和等待者，替换、失活、离窗或取消不能伪造成功。默认关闭眼睛跟随会话关闭；显式表情动作仍保留资格与真实完成校验。

## 日志、异常和装饰

✅ 首页最多展示三个 Channel 摘要，日志分 Action／Task／Agent 页签。显示值保留真实执行身份、状态、来源、排队／并发计数及淘汰数量；内部维护成功默认隐藏，失败可见。关闭摘要不取消执行，Tool 不虚构调度记录。

Task 详情按实际 task/call 身份关联 Action；独立的 Agent 聊天记录由设置历史页面呈现。缺失证据保持缺失，不推断物理回滚或执行成功。日志时间仅以半秒节奏刷新显示值。

ExecutionIssue 保留分类、短提示、最多2048字符详情及轮次关联。调用者决定 showsToast；UI 执行去重、身份替换、八秒到期及新输入撤销，保留日志。后台只记录不弹出，不在前台重放。replaceIssues 是独立宿主的纯值快照接口，当前应用使用 recordIssue。

Toast 为最多三行的黄色图标／文字，不拦截触摸，出现时让出回复／状态区。事实异常优先于装饰 Notice；装饰光不改变聆听同意或设备状态。

HomeEffectsWorkflow 拥有独立、可替换、按身份围栏的 Notice／光效到期任务和350ms回复清理任务。回复清理由外部完成策略触发；新文本、新轮次、停止可取消，stopAndWait 加入任务。Toast 到期由根拥有，不依赖页面存活。

## 生命周期与约束

共享根接纳及实时 token 拒绝后台、迟到和旧根更新；会话／轮次和日志 revision 校验仍由各自接口保留。失活解除表情等待并清理实时状态，停止加入期限任务。业务异常策略不在 UI 内决定。

❌ 持久化审计、设备实际阶段及完整真机动画／前后台验收仍独立跟进。

[UI 根](../README.md) · [原生组件](../Components/README.md)

✅ 首页两处字幕继续消费同一UI值，向TextRenderer字幕传递根代际；根失活或新根后不得继续旧淡入。字幕仍是页面局部呈现，不改变业务会话、音频及相机链路。

✅ 已实现：ConversationState增加与voicePhase独立的HomeModelPreparation；UIHomeContainer写入有生命周期接纳，inactive／stop清理。非就绪时禁新交互，但已活动会话仍可停止；加载眼睛复用原生Companion，不新增Canvas。真实加载不显示文字／按钮；失败仅显示重试按钮，Toast 由业务异常链路提交。

✅ 已实现：HomeBluetoothIndicator.swift统一拥有岛布局、展示目标和有限状态转换。蓝牙连接中／已连接，或ActionActivityState.hasOngoingTask为真时，两侧各24pt对称展开；任务来自当前任务ID及未终态任务快照（含后台／等待用户），不从回复、历史成功或日志显示过滤推断任务。右侧scope图标仅代表实际未结束任务。初始未连接不展开；蓝牙断连／失败投影为disconnected时立即灰色，保持150ms后用650ms原生动画缩回，完成上界800ms。任务仍在时岛身保持展开，蓝牙单独收回；任务结束且无蓝牙时整体收回。重连、任务变化从当前presentation值继续，过期动画按键替换；不创建延迟Task或timer。后台／离窗立即清理并落到紧凑状态，Reduce Motion直接落位。

✅ 已实现：公开安全区估算仍为岛身126×37pt、底边在安全区上方12pt。HomeBluetoothLayout.spectrumFrame只覆盖胶囊两个圆弧切点之间的直线，左右各避开18.5pt圆弧区；频谱硬遮罩同时裁掉外溢辉光，不在圆弧下绘制。收拢／展开分别将同一32频带原生视图水平缩放到89／137pt直线段，和岛身共用弹簧起点与时长；播放开始以顶部为锚点从零高度向下长出，底边不漂移。无蓝牙／任务时播放也只显示紧凑岛底频谱，不单独触发展开。ConversationIslandHeader独立观察连接、任务及播放值，非岛布局保留安全区回退。iOS没有精确硬件岛边框的公开查询接口，系统活动改变岛尺寸仍需真机检查。




✅ loading是独立EyeExpression状态，由ExpressionPresenting.setLoading按revision接纳；仅在实际准备且无已有交互时覆盖休眠，正常会话和表情基态保持。终态立即清掉加载覆盖，旧revision／后台迟到开启按 superseded 不呈现，停止后提交拒绝；启动占位在Agent尚不可用时保持闭眼，不伪装成模型加载。

✅ 加载接管会以取消结束旧的有限表情回执；加载期间新的有限表演明确拒绝为busy，不得把加载动画当作其他表情的完成回执。持续基态保留，退出加载后按当前会话／休眠状态恢复。

✅ 已实现：检查就绪与实际加载分离；只有 preparing 接纳加载眼睛，checking 不播放；启动占位保持闭眼，检查与加载均不提供手动取消入口。

✅ 已实现：加载投影返回 applied／superseded／rejected，正常旧版本或准备已结束的迟到开启不作为故障；被跳过的版本仍记录水位，同 revision 冲突和已停止根明确拒绝。

✅ 已实现：HomeModelPreparation 以 showsRetry 只允许 failed 显示重试；所有准备状态都不显示加载文字，preparing 的等待表情由独立 Expression Action 提交；检查不遮盖首页原内容。

✅ 请求等待属于可被有限表情演出覆盖的装饰，不使真实表情动作报 busy；模型实际加载仍保留原有独占契约。


## Direct container contract

UI-owned typed request/reply capabilities have one consumer and at most 64 outstanding requests, including accepted work. Acceptance does not complete a request. Cancellation, consumer exit, root invalidation and late replies are generation-fenced. Foundation dependencies remain empty. Current cross-module ownership is defined by the [overall design](../../README.md).

## Agent-owned UI inputs

✅ UIHomeContainer exposes ordinary HomeInput text requests and a separate control-only listeningRequests source. The listening source accepts submitControl only and permits one outstanding request; it is independent of text processing. Both sources follow the same UI root availability, generation, cancellation and stop rules. The business layer injects each source's owning container into its responsible consumer.

## 直连链路当前契约

✅ 类型化语音按压／切换请求直达角色，保留单槽控制入口与代际回执。
