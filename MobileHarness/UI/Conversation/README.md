# Conversation — 首页与运行记录呈现

## 职责与接口

UIHomeContainer 唯一创建 ConversationState、ActionActivityState、HomeEffectsWorkflow 和 ConversationExpressionPresentation，向业务分别暴露 ConversationPresenting、ActivityPresenting、HomeEffectsPresenting、ExpressionPresenting。

上游业务集成提交经会话／轮次验证的 UI 值；本目录消费 Components 的原生呈现，向上游转发聆听／重试意图及表情回执。没有 Signal 订阅、模型调用、设备控制或持久化。

## 文件与内部关系

| 文件 | 职责 |
| --- | --- |
| UIHomeContainer.swift | 子容器装配、共享根接纳及失活／停止 |
| ConversationState.swift | 会话值、字幕几何、呈现协议与表情事务 |
| ConversationView.swift | 首页和启动界面，隔离频谱、表情与字幕观察 |
| ActionActivityState.swift | Action／Task／Agent 日志值、异常、过滤及有界展示状态 |
| ActionActivityView.swift | 运行摘要、日志面板和详情 |
| HomeEffectsWorkflow.swift | Notice／装饰光／回复清理及其到期任务 |

✅ 日志值及异常呈现接口归 ActionActivityState，效果／表情协议与实现同文件；导航由 UI 根提供。首页消费真实状态，不包含另行构造的模拟记录或视觉演示页面。

## 字幕、表情与交互

✅ 半秒长按提交一次聆听切换；零距离拖动只提供按压和归一化光源位置，不直接打开设备。辅助功能激活使用相同控制端口。停止意图可打断回复；实际聆听和播放状态由外部执行者投影。

识别与回复分别占位：新的已接纳识别轮次清除前轮两段字幕，定稿的用户文本移到眼睛上方，回复保留在下方直到新一轮或明确清理。consent-off 清除字幕；普通生命周期暂停使旧 scope 失效。视图不推断 ASR 或播放完成。

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
