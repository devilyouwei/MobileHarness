# 精简 Writer 通信

删除 Writer 的 `task.progress`、`task.result`、`tool.result` 入站声明。WriterAgent 从返回型执行接口取得工具结果，删掉丢弃邮箱副本的分支。保留委派、补充、取消和投递回执四项入站。

Writer 终态保留一条持久业务通知 `writer.completion`。WriterNotifications 的收尾 worker 改为调用注册身份绑定的运行时接口。Agents Support 的 OutputGateway 与 AgentManager 核对执行者、会话和任务授权，复用现有的执行加入、取消和退休逻辑。只退休匹配的授权代际。历史作用域已不存在时完成收尾记录，仍在清理或校验失败时保留真实失败。现有 WriterMessages 存储结构保留两项独立确认，继续分别重试收尾及通知。普通跨角色任务的 `task.result` 继续按通用协议执行。

Assistant 的 Writer 终态接收只走认证的持久通知。继续从持久终态恢复委派视图，并保持通知容量、身份校验、去重及进度与追问的现有处理。同步 Writer、Agents Support、AgentCore Runtime、通信与跨模块设计说明。

验收覆盖精确入站与出站目录、工具结果直接返回、Assistant 拒绝通知时仍能退休旧授权并接纳新任务，以及持久通知重试无重复创作。执行 `scripts/check.sh` 和 `scripts/build-ios.sh`，记录证据。

Assistant FIFO 集成夹具使用同一绑定收尾端口关闭授权，保留通知早于或晚于收尾、队列拒绝和后续委派的覆盖。夹具停止模拟第二条 Writer 终态消息。

任务诊断原先消费已接纳的第二条终态消息。运行时收尾端口改为接受既有类型化终态值，并在成功加入和撤权后由 InputGateway 写入本地 trace。该 trace 不递送到 Agent，真实的收尾终态在用户通知拒绝时仍可观察。二十任务回归同时核对诊断记录与 Assistant 收件箱。

2026-11-09 完成。自动化与 iOS 模拟器构建通过。见 [验证记录](../validation/Writer-Communication-Reduction.md)。
