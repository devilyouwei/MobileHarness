# Writer 直接打开与进入工作区验证

## 真机故障定位

2026-11-10 在 iPhone 17 Pro 上只读检查 0.1.0（2026111002）的 Writer SQLite 记录。`call_4dcabfec7578483fa18aefb2` 首次调用 `workspace.open(workspaceID: "workspace_3")`，由 Writer 返回 `workspaceSearchRequired`。随后 `workspace.search` 按标题命中 `workspace_3`，重用同一 ID 打开 `window_2` 成功，之后进入同一工作区。临时数据库副本已清理。

## 回归范围

`writerOwnsTargetSelectionAndCompletion` 通过实际 Writer、Gateway、Artifacts 和临时 SQLite 覆盖直接打开、直接进入编辑、编辑中打开另一件作品后再切换，以及从搜索结果选择。未初始化的记录和不存在的 ID 产生工具失败，验证没有呈现窗口、创建草稿或建立编辑绑定。

- 17 个定向组合通过。`./scripts/check.sh` 通过 1109 个集成测试、229 个独立运行时测试和项目配置检查。
- `./scripts/build-ios.sh` 四个模拟器方案通过，应用资源检查通过。真机用于定位旧版故障，本轮修复的设备交互未执行。

## 2026-11-10 真机安装

- iPhone 17 Pro 原位更新至 Mobile Harness 0.1.0（2026111003）。签名、Agent 与 Skill 资源、Live Activity 扩展和新版 WriterWorkspace 教学校验通过。设备应用清单确认新版，系统启动成功。
- 本次验证覆盖安装与启动。真机上的 Writer 工具交互待验收。
