# Writer execution and streaming lifetime

日期：2026-11-06。范围：Writer 已接纳编辑的续写、取消和根清理；不改 Assistant 调度，不把内容分片转为 Action，不改 UI 文件导出路径。

## 目标与边界

Writer 保留独立模型循环。工作区 start/edit/render/finish 等工具经 Gateway direct 接纳与执行；edit 的完成仅代表创建编辑流，不代表文件内容生成或整个创作任务完成。ArtifactStreaming 是此编辑的宿主续写端口，delegateID/streamID 绑定同一个 Actions-owned 会话。Writer 拥有生成、任务取消和终态；Actions 拥有实际文件操作、会话准入和清理。Gateway 不为每个文本分片建立执行记录。

## 已发现问题

- ArtifactService 的 actor 方法在 editor/storage/presentation await 处可重入；complete/append/release 可交错，旧 Session 副本可能覆盖或恢复已经释放的会话。
- release 没有先关闭准入并加入在途操作；并发 release 没有统一清理结果。
- 流式 complete 没有在接纳前检查取消；未提供独立的立即撤销续写入口。
- ActionsBusinessAssembly 的根清理未加入 ArtifactService，宿主遗漏清理时编辑资源没有根级兜底。

## 拟定实现

1. `Actions/Support/Contracts/ArtifactStreaming.swift` 增加非阻塞的 `revoke(delegateID:)`：关闭该委托的普通续写/工具准入并请求取消在途工作；abort/release 仍能加入清理。已开始的 abort 只等待、不被后来的撤销或根关闭再次取消，避免 worker 取消与清理启动的竞态。release 是完成屏障；失败显式传播。恢复须在 release 后经 Gateway start/resume 创建新流，旧 streamID 永不复用。
2. `Actions/Artifacts/ArtifactService.swift` 统一跟踪工具、续写和截图操作，ArtifactWorkspace.swift 定义 closed 失败。全局至多八个在途操作、零等待队列；每委托一个变更操作及一个预览/截图操作，超限 busy。预览不占写入通道；预览更新只修改当前会话的预览字段，避免覆盖新编辑状态。工具校验原始会话 sessionID，不能只凭相同 delegateID 跨会话使用。
3. release 先围栏、取消并等待该委托的操作，再保存中断草稿、关闭 editor、释放项目锁；并发 release 合并。清理失败关闭服务准入并保留原错误，后续 release/shutdown 不报告虚假成功。shutdown 关闭全部准入、取消/加入工作并清理剩余会话。已发生的磁盘效果不回滚或伪装未发生。
4. `Agents/Writer/WriterAgent.swift` 在取消、暂停和停止时取消生成 worker 并撤销续写；worker 继续负责加入模型/预览、release 和终态。abort 在 checkpoint 失败时仍关闭编辑流并保留失败。
5. `Actions/ActionsBusinessAssembly.swift` 在现有根清理链加入 ArtifactService.shutdown，先结束编辑工作再关闭依赖的呈现能力。保留同文件其他在途修改。

## 文档与验证

实现后同步总体 README、Agents/Actions 根 README、Writer、Artifacts、Contracts README 和测试说明；删除当前文档把 preview 误称为绕过 Gateway 的描述。不创建新目录。

在现有 WriterAgentTests 增加可控挂起点回归：取消/撤销后的 append/complete 拒绝、跨 session 拒绝、release 等待真实在途效果且拒绝迟到操作、并发清理、根关闭与重新准入拒绝、旧流在恢复后无效、预览与续写独立。使用现有真实 Gateway/SQLite Writer 参数化回归验证工作流。

执行专项回归、`./scripts/check.sh` 和可用 Xcode 下 `./scripts/build-ios.sh`；记录失败与不可用项。模型/原生 UI/设备验收不由这些替身测试替代。

## 实施状态

实现及当前设计文档已完成。专项 10 项测试、完整 `scripts/check.sh`（含 1,051 项集成测试和 227 项原生运行时测试）、四目标 Simulator 构建均通过，2026-11-06 归档。详细结果及迭代失败见 [验证记录](../validation/Writer-Execution-Lifetime.md)。真实模型与真机验收不属于这次生命周期修正的自动化证据。
