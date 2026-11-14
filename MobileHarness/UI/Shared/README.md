# Shared — UI内部共享机制

## 职责与关系

供根组合、公共组件和功能子容器复用的非视觉机制，仅依赖Foundation；不引用Camera、Settings、Conversation、Root或业务模块。UI仍为同一Swift target，目录不引入新编译模块。

| 文件 | 职责 |
| --- | --- |
| UIRequests.swift | 泛型请求/回执、单消费者、容量和取消围栏 |
| UIPresentation.swift | 呈现接纳、可用性接口与代际凭证 |
| ExecutionIssue.swift | 调用方提供的结构化运行故障与呈现值 |
| AppLanguage.swift / Localizable.xcstrings | Preference values, locale resolution, and lookup of app-owned presentation copy. |

模块级失败/回调与State契约分别位于根下[UIFailure.swift](../UIFailure.swift)和[UIStateSnapshot.swift](../UIStateSnapshot.swift)。具体输入/回执跟随功能owner，不在此集中定义；呈现凭证只授权UI状态接纳，不代表设备或业务权限。失活使旧实时凭证失效，停止关闭所有接纳；失败保留原始错误和清理错误，由上层决定如何展示。

## Direct container contract

UI-owned typed request/reply capabilities have one consumer and at most 64 outstanding requests, including accepted work. Acceptance does not complete a request. Cancellation, consumer exit, root invalidation and late replies are generation-fenced. No other project module is imported. Current cross-module ownership is defined by the [overall design](../README.md).

Control requests use a separate single-slot stream under the same consumer lifetime. They can execute while ordinary work awaits completion; overflow rejects explicitly. Ordinary outstanding work stays bounded to 64.

## Agent-owned UI inputs

UI subcontainers expose typed request sources. The injected business consumer owns listening and processing; UI retains receipt identity, capacity and generation only. Home text uses the ordinary request source; home listening has a control-only single-slot source and cannot enlarge the ordinary 64-request bound. Both sources share root availability/stop. UI keeps no Agent identity or business execution authority.

订阅关闭携带消费者 token，旧订阅退出不能关闭恢复后的消费者；恢复前加入旧消费任务。暂停期间仅允许经身份校验的本地取消／retire 清理，不接纳新的业务请求。

## 直连链路当前契约

页面只向 Container 提交语音／检测请求；UI 不持有检测业务任务，业务呈现经 Actions。

性能采样：仅在显式 `-direct-input-measurements` 启动参数开启时记录 UI 排队／完成及 PCM／相机接纳年龄；不记录内容或原始媒体，默认关闭。

## Request cancellation ownership

A request owns one cancellation callback bound to its Agent-owned processing task. Page cancellation, root invalidation and consumer closure cancel admitted work as well as ending the receipt. The Agent joins its task before consuming replacement ordinary work; the source and unrelated requests remain available. The common consumer owns the existing 120-second deadline, removing role-specific deadline wrappers. No event bus or media buffer is added.

[UI模块](../README.md)

`ExecutionIssue` 为日志和首页提示提供共同的显示值。失败报告端口由应用注入，各生产者提供关联身份和结构化失败码。

The shared localization catalog includes Agent and execution-log status, completion and formatted issue copy. Agents supplies AppLanguage at projection time; raw business values and original diagnostic strings are not catalog keys. Format strings keep item numbers, motor identity and target/observed values as arguments.
