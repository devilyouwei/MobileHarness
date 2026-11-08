# Writer 委托与 Workspace 解耦

2026-11-08 用户批准实施。单一 writer_messages 保存委托入口、模型调用和补充输入；入口保存执行生命周期，子消息以入口关联完整委托，workspace 为空表示前序。writer_tasks 收窄为 writer_workspaces，只拥有文件、标题、租约及删除标记。不新增 writer_requests。

## 行为与边界

接收只创建入口；select 或首次 edit 准备成功绑定 workspace。发起选择/创建的模型消息不搬移，之后产生的消息带 workspace。单次请求最多一个编辑目标，纯库操作不创建 workspace。消息按数据库分配主键排序，revision 不作顺序。终态与 outbox 原子保存到入口，不伪造模型消息。删除作品保留历史身份。

UI 顶部委托统计与详情（来源、原始输入、状态、前序及 workspace 链接），下方 workspace 列表与消息流，无委托段号。列表分页与返回保留既有修复。

## 实施责任

WriterMessages 接收原 WriterTasks 的执行仓库、请求类型与通知操作；WriterWorkspaces 接收作品及文件索引契约。沿用 StorageTasks/StorageChat/StorageSQLite target 边界，修改 Package 显式文件清单、App 注入和 Agent 运行上下文。同步各 owner README、Storage/UI/Agents 及总体跨模块设计。Writer 自己拥有提示词，不改 Assistant。

## 开发重置与验证

用户授权丢弃全部旧 SQLite 与 Writer workspace 文件及预览缓存；保留配置、密钥、模型。启动前幂等完成重置，失败阻止业务启动，不迁移旧数据。测试入口唯一、前后边界、纯库完成、两委托同 workspace、失败/等待/取消/恢复、分页/来源/日志清理。执行 check.sh、build-ios.sh；原生验收独立记录。

## 实施进度

存储、执行链、UI、导出、启动重置及文档已实现；新增回归与 iOS 四方案构建通过。原生页面验收在应用启动/accessibility 查询阶段阻塞，尚未进入 Writer 页面；因此保留本需求，未完成验收前不归档。完整检查初次失败与串行复跑、相机套件缺口及原生过程详见 [验证记录](../../validation/Writer-Workspace-Separation.md)。

执行边界补充：忙碌时拒绝的入站仍保留唯一入口及失败原因，但不抢占当前执行上下文；当前上下文选择排除未接纳入口。历史查询独立于运行上下文。删除 tombstone 不能再次获取写租约。纯查询完成允许没有 workspace 标识。

## 2026-11-08 作品库与工作区分域执行

真机首个委托的前序请求先调用 projects，随后直接调用 edit(index.html)。后者隐式分配工作区，两个请求共用控制提示词。新版将工作区进入作为显式工具和模型上下文边界。

- Storage/WriterWorkspaces 提供数据库内标题、目标和已知 task_N 的关键词查询，按工作区 ID 倒序分页，仅投影匹配的元数据。Artifacts 将其暴露为 searchWorkspaces(query,before?)。普通搜索使用关键词，只有用户明确要求浏览作品库时使用空查询，且每次只返回一页。
- Writer 前序域提供 searchWorkspaces、enter、create、open、delete、ask、finish。先查询，使用实际搜索命中的 ID 进入或打开；有多个候选且目标不明确则追问。目标允许新建时可显式 create(title,entry)，分配目录、准备空草稿与入口窗口，再进入文件域。仅查看使用 open，呈现已有内容并切换只读汇报域。前序域无法调用文件工具。enter/create/open 单独调用，目标绑定后不允许切换。
- WriterWorkflow 在域切换时记录触发工具结果，下一请求以新的 system 模板和工具目录开始。跨域只传原始任务、已接受补充和已验证的工作区身份、标题、入口与呈现状态。旧域模型和工具消息仍在 SQLite 审计，暂停或追问后只恢复当前域的完整调用组。继续沿用既有模型快照和委托身份，保持前序行的 workspace_id 为空。
- Artifacts 在创建或进入时请求真实窗口呈现，空工作区只展示临时占位。文件流通过现有预览路径更新同一窗口。场景不可见时返回 deferred，保存最新快照供恢复；用户后续关闭/最小化遵守现有策略。Writer 使用实际呈现状态汇报。现有作品纯查看不写草稿。
- 窗口转换被打断但窗口仍保留时，Actions 为该窗口准备页面内容并返回延后状态，避免窗口回到可见区域时只出现空壳。关闭仍由真实关闭事件处理。
- 修改现有 Writer、Artifacts、WriterWorkspaces、WriterMessages 及总体技术说明，不变更 schema。回归覆盖查询范围和分页、无匹配新建、匹配进入和打开、前后域提示词及目录隔离、预览窗口早于文件写入、暂停与补充、既有历史分组和关闭/隐藏场景。

## Writer 请求详情的单向导航

委托详情和 Workspace 消息列表都可以进入请求详情。UI/Settings 移除请求详情中的「委托来源」分区和回到委托详情的入口，避免通过前序请求重复推入同一委托页。委托详情仍展示来源信息。请求详情只提供已验证的较早工具调用来源链接，并通过系统返回按钮回到原列表。更新原生 UI 回归，分别覆盖前序和 Workspace 请求无委托回链，以及返回后列表页保留。

## 锁屏后恢复作品预览

真机已发布的 Writer 作品在解锁后出现 Actions 生命周期错误，原因为窗口恢复时的 WebKit 超时。Actions/Artifacts 将前台作品预览恢复放在单个根持有任务中。前台准入与其他模块恢复可以继续，单窗口失败保留最新快照并显示窗口级诊断，其他窗口继续恢复。隐藏与 Actions 停止取消并加入恢复任务，迟到结果受场景和项目锁约束。显式渲染、文件保存及相机、蓝牙清理保留各自错误契约。更新 Artifacts、Actions 与跨模块生命周期说明，并回归窗口故障隔离、再次恢复及锁屏取消。
