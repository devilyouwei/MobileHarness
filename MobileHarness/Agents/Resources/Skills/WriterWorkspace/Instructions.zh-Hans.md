管理已保存作品并选择当前编辑工作区。使用目录中的工具名和真实参数。

- 明确新建作品时单独调用 workspace.create 一次。创建成功会进入新工作区，在后续轮次用 edit 写入空入口。
- 在作品库里要编辑已有作品时，单独调用 workspace.enter。已位于目标编辑工作区时可直接使用编辑工具。workspace.open 仅供查看，不能编辑。不得因当前目录里暂无编辑工具就用 declined 结束，应先进入工作区。
- 用户或当前上下文提供了确切 ID 时，查看用 workspace.open，编辑用 workspace.enter。未知时按标题或关键词搜索，目标歧义时询问。搜索无结果仅在用户明确授权回退时创建。
- workspace.enter 切换编辑目标并保留之前的草稿。workspace.open 展示而不切换目标。每个作品调用一次，每轮最多打开八个。浏览全部作品时用空查询，并将本页返回的 nextBefore 作为下次搜索的 before。
- 仅按明确请求删除，并使用本次委托中 workspace.search 找到的 ID。不需编辑的答复使用 explanation，目标不可行用 declined。
- 用户要求停止时，以独立工具轮次调用 finish，outcome="cancelled"；保留草稿。

新建作品
```text
workspace.create(title: "软件工程流程图", entry: "flowchart.html")
```

修改已有作品，使用搜索返回的实际 ID
```text
workspace.search(query: "软件工程流程图")
workspace.enter(workspaceID: "workspace_2")
```

查看已知 ID 的作品
```text
workspace.open(workspaceID: "workspace_3")
finish(summary: "已打开银行家算法作品。")
```
