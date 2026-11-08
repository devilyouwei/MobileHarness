# Assistant / Writer 任务入口与作品归属

## 需求与原因

2026-11-08 用户截图显示绘图请求先 task.start、再 task.delegate。现有资源虽说委派无需前台任务，仍向 Assistant 暴露 writing Skill 和 Artifact_library，且未明确同一目标的入口选择。

- task.start 与 task.delegate 为平级入口。Assistant 自己执行、需跨轮保留的前台目标才 start；写作、绘图、文件修改、作品搜索/打开/管理直接委派 Writer，同一目标不先 start 或加载 Skill。
- 两个独立目标可同时存在；委派不能结束、替换或污染已有前台目标。busy 时补充/取消沿用现有协议。
- 删除 writing 资源和索引；Assistant 不能加载它，也不能直接调用作品库。
- Writer 原生工具负责列举、按返回身份打开/删除作品；删除仍需用户明确要求。只查看不生成或发布空作品，不把工具接纳说成成功。

## 实施范围（代码修改前）

1. Resources/Catalog、Assistant Instructions、BasicSkill、WebBrowsing：统一入口选择与职责，删除 Writing，递增变更 Skill revision；Actions/System/Task 的 canonical doc 同步。
2. Agents/Writer/WriterAgent、WriterWorkflow：暴露 projects/open/delete，已有可信委托身份保持不变；编辑工作区延迟到首个文件操作才初始化，单纯作品查询/打开不创建草稿。只读库操作通过真实结果完成，不走文件发布检查；实际编辑仍必须 render/finish。取消、暂停和清理沿用根拥有的 worker 和 ArtifactStreaming 屏障。
3. Actions/Artifacts/ArtifactService、WorkspaceActions：作品库改为 Writer 原生操作，返回身份只选择作品不改变执行 owner；仍持有项目锁，失败原样返回，拒绝 Assistant。
4. Tests/IntegrationTests：资源不可加载/不可调用、路由教学、无前台委派、库操作成功与失败、只查看不发布、编辑完成约束回归。
5. 实施后同步总体、Agents/Writer/Assistant、Actions/Artifacts/System/Task、资源与测试 README；历史记录保留当时 Writing 描述。

## 验证

执行 ./scripts/check.sh 与 ./scripts/build-ios.sh，记录实际结果。脚本与替身验证不代表真实模型路由或手机 UI 验收；截图场景需独立复验。不得修改无关工作区内容或新增目录。

## 实施状态

资源、入口教学、Writer 作品库与延迟编辑工作区、回归测试和当前设计文档已更新。本次专项回归和 iOS 构建通过；全量普通测试保留一项范围外机械臂断言失败。真实模型/手机复验尚未执行。完整脚本结果及验收边界见 [验证记录](../../validation/Assistant-Writer-Task-Routing.md)。
