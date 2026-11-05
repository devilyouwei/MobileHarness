# Conversation — 首页与运行记录呈现

首页触摸仅在 LongPressGesture 半秒门槛成功后提交一次 toggle；短按、双击、抬起和页面退出不提交 press 准备请求。拖动仅更新本地光源位置，长按视觉状态保持本地 GestureState。内部 press 能力保留兼容接口，首页不使用；实际启动提示音仍由聆听执行流程拥有。

ConversationState 单独拥有 replyWaitingRequest；首个输出、匹配清理、新回复、停止聆听、恢复聆听和失活解除等待，旧请求不能清除新请求。模型准备 checking／ready 不清除请求等待。

HomeModelPreparation 只在 failed 提供重试资格；移除 cancelled 用户状态、消息文案及手动取消端口。首页恢复提示仅含重试按钮，加载时没有文字／按钮；真实加载眼睛仍由表达 Action 接纳。

## 职责与接口

UIHomeContainer 唯一创建 ConversationState、ActionActivityState、HomeEffectsWorkflow 和 ConversationExpressionPresentation，向业务分别暴露 ConversationPresenting、ActivityPresenting、HomeEffectsPresenting、ExpressionPresenting。

上游业务集成提交经会话／轮次验证的 UI 值；本目录拥有Face原生呈现，并消费 Components 的字幕、频谱和覆盖组件，向上游转发聆听／重试意图及表情回执。没有 Signal 订阅、模型调用、设备控制或持久化。

## 文件与内部关系

| 文件 | 职责 |
| --- | --- |
| UIHomeContainer.swift | 子容器装配、共享根接纳及失活／停止 |
| ConversationState.swift | 会话值、字幕几何、呈现协议与表情事务 |
| ConversationView.swift | 首页和启动界面，隔离频谱、表情与字幕观察 |
| ActionActivityState.swift | Action／Task／Agent 日志值、异常、过滤及有界展示状态 |
| ActionActivityView.swift | 运行摘要、日志面板和详情 |
| HomeEffectsWorkflow.swift | Notice／装饰光／回复清理及其到期任务 |

日志值及异常呈现接口归 ActionActivityState，效果／表情协议与实现同文件；导航由 UI 根提供。首页消费真实状态，不包含另行构造的模拟记录或视觉演示页面。

## 字幕、表情与交互

半秒长按提交一次聆听切换；零距离拖动只提供按压和归一化光源位置，不直接打开设备。辅助功能激活使用相同控制端口。停止意图可打断回复；实际聆听和播放状态由外部执行者投影。

HomeEffectsWorkflow.replyDidFinish只撤下回复等待指示，不清空转写或回复文本、不启动回复到期淡出。字幕结束后保留，清理由各自拥有者显式提交；UI不根据ASR／播报完成决定业务寿命。

识别与回复分别占位：SpeechPerception在确认新的人声轮次后显式提交空转写，presentTranscript只更新用户槽并解除该槽定稿标记；Assistant收到输入开始控制事件后单独清理回复槽。定稿的用户文本移到眼睛上方，回复及恢复聆听期间保留两段字幕。停止聆听保留字幕，只撤下等待指示并改变呈现门；根失效或显式会话重置才整体清理。普通生命周期暂停使旧scope失效。视图不推断 ASR 或播放完成。

ConversationCaptionLayout只计算字幕，任务目标由根灵动岛展开区显示，Face不重复放置任务条或预留空位。用户字幕位置只随定稿边界动画。Components 在显示边界保留最新320个完整 Characters。

表情基态只提交状态；有限表演拥有独立身份和等待者，替换、失活、离窗或取消不能伪造成功。默认关闭眼睛跟随会话关闭；显式表情动作仍保留资格与真实完成校验。

## 日志、异常和装饰

首页最多展示三个 Channel 摘要，日志分 Action／Task／Agent 页签。显示值保留真实执行身份、状态、来源、排队／并发计数及淘汰数量；内部维护成功默认隐藏，失败可见。关闭摘要不取消执行，Tool 不虚构调度记录。

Task 详情按实际 task/call 身份关联 Action；独立的 Agent 聊天记录由设置历史页面呈现。缺失证据保持缺失，不推断物理回滚或执行成功。日志时间仅以半秒节奏刷新显示值。

ExecutionIssue 保留分类、短提示、最多2048字符详情及轮次关联。调用者决定 showsToast；UI 执行去重、身份替换、八秒到期及新输入撤销，保留日志。后台只记录不弹出，不在前台重放。replaceIssues 是独立宿主的纯值快照接口，当前应用使用 recordIssue。

Toast 为最多三行的黄色图标／文字，不拦截触摸，无回复时占用状态区。事实异常优先于装饰 Notice；装饰光不改变聆听同意或设备状态。

HomeEffectsWorkflow只拥有独立、可替换、按身份围栏的Notice／光效到期任务，stopAndWait加入这些任务。回复字幕没有到期任务；ConversationState.clearReply只清回复槽，presentTranscript只更新转写槽，二者的业务调用时机归各自Agent。Toast到期由根拥有，不依赖页面存活。

## 生命周期与约束

共享根接纳及实时 token 拒绝后台、迟到和旧根更新；会话／轮次和日志 revision 校验仍由各自接口保留。失活解除表情等待并清理实时状态，停止加入期限任务。业务异常策略不在 UI 内决定。

持久化审计、设备实际阶段及完整真机动画／前后台验收仍独立跟进。

[UI 根](../README.md) · [原生组件](../Components/README.md)

首页两处字幕继续消费同一UI值，向TextRenderer字幕传递根代际；根失活或新根后不得继续旧淡入。字幕仍是页面局部呈现，不改变业务会话、音频及相机链路。

已实现：ConversationState增加与voicePhase独立的HomeModelPreparation；UIHomeContainer写入有生命周期接纳，inactive／stop清理。非就绪时禁新交互，但已活动会话仍可停止；加载眼睛复用原生Companion，不新增Canvas。真实加载不显示文字／按钮；失败仅显示重试按钮，Toast 由业务异常链路提交。

loading是独立EyeExpression状态，由ExpressionPresenting.setLoading按revision接纳；仅在实际准备且无已有交互时覆盖休眠，正常会话和表情基态保持。终态立即清掉加载覆盖，旧revision／后台迟到开启按 superseded 不呈现，停止后提交拒绝；启动占位在Agent尚不可用时保持闭眼，不伪装成模型加载。

加载接管会以取消结束旧的有限表情回执；加载期间新的有限表演明确拒绝为busy，不得把加载动画当作其他表情的完成回执。持续基态保留，退出加载后按当前会话／休眠状态恢复。

已实现：检查就绪与实际加载分离；只有 preparing 接纳加载眼睛，checking 不播放；启动占位保持闭眼，检查与加载均不提供手动取消入口。

已实现：加载投影返回 applied／superseded／rejected，正常旧版本或准备已结束的迟到开启不作为故障；被跳过的版本仍记录水位，同 revision 冲突和已停止根明确拒绝。

已实现：HomeModelPreparation 以 showsRetry 只允许 failed 显示重试；所有准备状态都不显示加载文字，preparing 的等待表情由独立 Expression Action 提交；检查不遮盖首页原内容。

请求等待属于可被有限表情演出覆盖的装饰，不使真实表情动作报 busy；模型实际加载仍保留原有独占契约。

## Direct container contract

UI-owned typed request/reply capabilities have one consumer and at most 64 outstanding requests, including accepted work. Acceptance does not complete a request. Cancellation, consumer exit, root invalidation and late replies are generation-fenced. Foundation dependencies remain empty. Current cross-module ownership is defined by the [overall design](../../README.md).

## Agent-owned UI inputs

UIHomeContainer exposes ordinary HomeInput text requests and a separate control-only listeningRequests source. The listening source accepts submitControl only and permits one outstanding request; it is independent of text processing. Both sources follow the same UI root availability, generation, cancellation and stop rules. The business layer injects each source's owning container into its responsible consumer.

## 直连链路当前契约

类型化语音按压／切换请求直达角色，保留单槽控制入口与代际回执。

回复文本存在时暂停首页 Notice 展示，避免连续异常遮挡字幕；新回复撤下错误 Toast，完整异常继续保留在日志。

## Expression state projection

ConversationExpressionPresentation.expressionSnapshot reads its actual base expression and override owner plus ConversationState.displayedExpression, transition waiter, renderer availability and loading. The effective value is a display target; transition completion remains the renderer's existing identity-matched acknowledgment. Cancellation/restoration clears only its owner and restores the current base. ConversationExpressionPresentation owns the ui.home.expression local State reader. UIHomeContainer only returns that child path index; its stateReaders catalog binds the existing expression owner without reading its state.

UIHomeContainer.stateSnapshot contains only home interaction facts and an expression index. Ready/admission and renderer availability remain Runtime. The container provides no Assistant-specific expression snapshot.

voicePhase uses the declared VoicePhase raw values for user-interaction activity; it is distinct from renderer/admission readiness in Runtime.

蓝牙/Task/语音摘要由根双呈现灵动岛承载，ConversationView保留底部聆听频谱；App侧回复频谱由通用紧凑组件承载，系统侧语音附件为状态符号、不发送实时频带。本目录提供原有呈现事实，不持有岛身或布局。

## Face原生实现

NativeCompanionSurface、EyeGeometry、ListeningMotion、MetalHaloRenderer与ListeningHalo.metal同属本目录，shader由UI SwiftPM target处理。UIHomeContainer同时定义HomeInput；输入类型不进入Shared。

## 眼睛与光源

全部表情共用八段顺时针三次曲线及对应控制点，形状插值保留连续接点；不交换表情图片。眼宽、间距、眼高分别按脸宽的21%、19%、25%布局。视线使用归一化输入及有界位移。

原生路径／shadowPath／变换从 presentation 当前值开始插值，持续基态和有限表演身份分开。常规变化650ms，唤醒180ms，闭合460ms，视线320ms；Reduce Motion 简化重复动画。眨眼和呼吸为独立图层动画，唤醒后延迟启动，休眠／失活／离窗时停止。完成回调不能将替换或不可用当作成功。

ListeningLightOrigin 接受有限归一化坐标并逐轴回退／截断；ListeningMotion 仅在新 generation 锁定光源和起点。眼睛、光环使用同一时刻提交，稳定期改变光源不会移动正在运行的波。装饰光有独立身份；移除装饰覆盖不会重播聆听唤醒。

## Metal 光环

管线离 MainActor 准备；一个全屏三角形绘制扩散前沿、尾部及边缘光，不叠加全屏 SwiftUI 模糊。入场初始透明度至少0.85，进入／退出透明度各320ms，扩散约720ms并在约1.05秒稳定。Reduce Motion 保留静态场和简化过渡。

渲染器拥有独立线程和 CAMetalDisplayLink；一个最新快照、最多一个合并唤醒、最多三个 GPU 在途命令。满载跳过显示机会，不累计帧。过渡请求屏幕支持的刷新率，稳定流动请求60Hz，无需更新时暂停；请求不保证实际帧率。停止关闭接纳，在线程上注销显示链并等待真实 GPU 完成，不阻塞主线程。

光环线程句柄与退出标记统一由锁保护；Thread 句柄本身不具备 Sendable，控制结构仅以锁保护的引用发布／唤醒方式跨域，采用与相机相同的受限 unchecked Sendable 契约；退出使用可明确停止的 RunLoop；等待真实 GPU 完成后归还全部槽位，并提供非主线程完成屏障。频谱固定颜色／线宽／布局仅在对应配置变化时提交，数值变化只更新路径。

管线／GPU 失败通过注入回调报告；眼睛仍保持自己的动画完成语义。布局仅在 frame、scale 或 drawableSize 变化时更新，禁用隐式事务。

光环故障对当前实例锁存并停止接纳，仅报告首次故障；相同运动／尺寸／可见性不唤醒线程，刷新率仅变化时提交。失败只停止光环，眼睛仍独立回执；新渲染实例重新接纳。保持GPU完成回收与现有帧率。

loading双眼采用同拓扑睁眼轮廓，独立父图层由 Core Animation 按1.2秒周期缩放，左右在1.12与0.68之间反向交替；位置与明暗保持。缩放与眼形／镜像／视线变换分离，不增加线程、Canvas或逐帧Task；减少动态效果时保留静态大小眼，终态／离窗／后台／销毁移除循环并恢复缩放，不依赖Metal光环或聆听启用。

首页和启动占位不再自行铺设背景或暗色遮罩，由Root统一提供深蓝至黑色渐变；本目录只呈现眼睛、光环、字幕和交互。
