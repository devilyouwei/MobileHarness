# Writer 工具注册拆分

- Actions 为作品库检索、打开和删除，以及文件读取、变更、渲染分别注册独立函数，由单一声明投影模型参数并校验调用。注册入口统一复用 ArtifactService 的锁、工作区与流式编辑。创建或进入编辑会话、预览、字幕更新和发布使用 Writer 内部注册，去掉通用 perform 路由。
- Writer 在作品库和编辑阶段从对应 Skill 的绑定生成工具目录。进入、创建、追问、结束由 Writer 的本地工具管理委托和工作区上下文。结束仍要求显式 finish。已有 ID、批量打开和发布校验保持原契约。
- Workflow 根据实际工具名处理独占轮次和恢复；History 记录真实注册路径，恢复时把旧调用作为历史证据保留。记录 UI 识别新工具名和既有记录格式。
- 更新 Artifacts、Writer、Skills 和总体架构说明，覆盖声明、分域、Gateway 路由、历史和流程回归。

实施日期为 2026-11-09。检查结果见[验证记录](../validation/Writer-Tool-Separation.md)。
