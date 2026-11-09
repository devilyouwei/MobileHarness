# Writer 按已知 ID 直接打开和进入工作区

真机上的 `call_4dcabfec7578483fa18aefb2` 传入 `workspace_3`，因当前委托没有搜索缓存而被拒绝。随后按标题搜索，再用同一个 ID 打开成功。已知精确 ID 时，搜索增加一次工具调用和一次模型决策。

- Writer 在 `WriterAgent` 按精确 `workspace_N` 查验目标是否存在且可用。`workspace.open` 直接呈现已有作品，`workspace.enter` 直接绑定编辑目标。无效、缺失或未就绪的 ID 返回可修正的工具观察，不初始化工作区、不切换编辑目标。删除继续要求用户明确授权和本委托实际搜索命中。
- `WriterWorkflow` 的 enter 声明、Artifacts 的 open 声明和 WriterWorkspace Skill 教学区分已知 ID 与按标题发现。已知 ID 可来自用户、当前上下文或搜索结果。目标不清楚时搜索或追问，禁止猜测。
- 同步 Writer 与 Artifacts 的当前技术说明。回归覆盖无搜索直接打开、进入与切换，以及不可用 ID 无文件和窗口副作用。运行 `./scripts/check.sh` 与 `./scripts/build-ios.sh`。

[验证记录](../validation/Writer-Direct-Workspace-Access.md)
