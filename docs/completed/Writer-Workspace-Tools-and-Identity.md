# Writer 工具与工作区身份

## 接口与行为

WriterWorkspace Skill 暴露 workspace.search、workspace.create、workspace.enter、workspace.open、workspace.delete。文件工具保持短别名。ask 和 finish 在两个阶段共用。Actions 声明函数及参数语义，Skill 用短规则和调用示例教学。Writer 按阶段组装工具，并通过已有 native tool 映射调用。

明确新建直接 create，先校验相对 HTML/Markdown/TXT 入口路径，再分配、创建空入口和进入。源文件正文由 edit 写入。保留同一委托的创建预留和重复保护。enter、open、delete 使用当前委托搜索命中的 ID。文件搜索和 diff 使用现有分页，不声明未使用的 limit。

## 数据与所有权

StorageCore 定义 workspace_N 身份，Writer、Artifacts、SQLite、历史、UI 和导出使用 workspaceID，磁盘使用 writer/workspace_N。委托生命周期仍使用独立 delegateID。同步 WriterWorkspaces、WriterMessages、WorkspaceFiles、Artifacts、Writer、Settings 及总体设计。共享 Assistant 前台 Task 与 task.* 路由维持原定义。

workspace_files.workspace_id 关联 writer_workspaces。递增 schema 版本并沿用启动重置，旧共享数据库及 Writer 工作区、预览被清空。保留配置、密钥和模型。无旧 schema、别名或 workspace ID 兼容。

## 验收

覆盖直接新建、非法入口无分配与呈现、修正和重复保护、已有作品多开与切换、两阶段 finish、别名映射、外键与重置、历史和原生 Settings。运行 check.sh 与 build-ios.sh，单独记录真实模型首个调用与原生 UI 验收。

验收结果见 [验证记录](../validation/Writer-Workspace-Tools-and-Identity.md)。
