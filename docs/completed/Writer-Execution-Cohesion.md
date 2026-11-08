# Writer 请求与作品选择内聚

2026-11-08，用户授权修改优化业务代码。修改前记录设计；不新增目录，保留并行工作区改动。

## 问题

请求接纳阶段以 description 子串猜测已有作品，提前绑定文件目标。模型查询到实际作品后不能接续编辑，暴露了内部流程缺口。无产物说明被当作未完成；失败缓存也阻止 render 后重新发布。

## 设计与归属

- WriterAgent 接收认证通信，只建立 Writer 私有的本地请求任务，不按自然语言猜测目标。通信 ID 仅关联消息、输入和回报，不是外部前台任务。删除 selectedWorkspace 文本匹配。明确拒绝入站 payload 的 taskID/workspaceID，避免未解码的 workspaceID 绕过本侧身份校验。
- Writer 的 native select(taskID) 选择查询返回的已有作品。open 仍只展示。select 在第一次文件操作前执行；不存在、已删除、忙碌、已有编辑效果的跨目标切换均明确拒绝。同一目标可幂等确认。只读文件操作在尚未选择/创建工作区时返回错误，不顺带创建空作品；新建仍从首次 edit 开始。
- WriterTasks 仓库提供原子目标接续：只允许将无 workspace、无文件租约且只含当前请求消息的临时本地任务接到已有 ready 作品；当前请求及其消息移到目标任务，消息 ID、工具调用/结果、通信 ID 保持不变，顺序追加，旧作品历史保留。空的临时任务删除，避免重复任务/作品。事务失败不改变任一目标。它只做存储校验和事务，不做标题匹配或业务选择。
- WriterHistoryStore 提供在工具检查点刷新当前任务的机制：先持久化当前待执行工具记录，再进行事务接续，再重载历史。保持在途工具 ID，不能把工具执行中的消息标成中断。失败显式传播，禁止继续使用过期任务。WriterHistory 后续请求读取最新本地任务身份。
- WriterTaskRepository 旧 beginDelegation/delegatedTask 等接口改为本侧 request/task 命名，调用方同步，不保留重复兼容实现。跨 Agent 的 task.delegate 通信协议不改，Assistant 不参与作品定位。
- finish 增加 Writer 私有 outcome=explanation，用于无文件效果的能力限制说明；返回明确无产物结果，不伪装为作品发布。已开始编辑的任务仍要求 render/publish，不能以 explanation 跳过。普通库操作沿实际结果结束。
- WriterWorkflow 在成功执行 render 后，仅失效此前因 renderRequired 被拒绝的 finish 缓存；成功 select 同样只失效 workspaceSelectionRequired 的失败缓存；仍由 Artifacts 校验最新草稿和诊断，保留其他失败效果的抑制和恢复次数上限。

## 影响文件与验证

修改 Agents/Writer 的接纳、工具适配、历史、恢复与自有资源；Storage/Database/WriterTasks 的专属接口/事务与 WriterMessages 历史刷新；同步测试、评估器及相关 README。Actions.Artifacts 仍拥有文件/渲染/发布；Gateway 仍拥有通信身份和执行认证，无新能力迁入基础模块。

回归包含：同一请求查找后编辑；同名澄清后继续；历史/通信身份与重启持久性；无目标 read 不建 workspace；错误目标及编辑后切换拒绝；无文件说明与未完成编辑的区分；提前 finish → render → 相同 finish 恢复；重复失败有界。复测 Qwen3.8 Max、GPT6.1 sol，使用已授权 env.local。执行 check.sh、build-ios.sh，并记录模型/桌面窗口/构建边界。更新总体及 Agents、Storage 相关设计文档，结果另存 validation，不改写原实验。

## 完成与验收

已实现上述业务、存储、私有提示及恢复调整，移除旧目标猜测与旧仓库接口名称。七模式业务回归和原子拒绝测试通过；两模型完整矩阵均 30/30，check.sh 和四个 iOS Simulator 目标构建通过。完整证据与桌面/真机边界见[验证报告](../validation/Writer-Execution-Cohesion.md)。本需求未把真机验收列为完成条件，本轮未执行真机测试。
