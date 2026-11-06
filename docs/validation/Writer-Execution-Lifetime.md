# Writer execution lifetime validation

日期：2026-11-06。范围：Gateway 工具接纳后的 Writer 续写、撤销与加入清理；[完成计划](../completed/Writer-Execution-Lifetime.md)。

## 实现与证据范围

Writer 保留独立 Tool 工作流，文件分片继续经 ArtifactStreaming 背压直达 Actions。测试使用真实 ArtifactService、ActionsContainer、Gateway（原有角色集成场景）、StorageFiles 和 SQLite；模型、挂起的呈现效果及检查点阻塞均为明确夹具。不涉及付费模型请求，也不作为原生 WebKit、实际窗口、物理设备或进程被系统杀死后的验收。

## 已执行验证

| 检查 | 结果 |
| --- | --- |
| Actions 模块独立构建（Xcode 工具链） | 通过。 |
| Writer 专项 Swift Testing | 10 项测试全部通过，含原有后台角色 13 个模式及两个参数化并发用例；运行约 2.96 秒，不含编译。 |
| `./scripts/build-ios.sh` | 四目标全部通过：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero；应用 Agent/Island 资源检查通过。 |
| 本次修改 Swift 文件 strict format lint | 通过。 |
| `git diff --check` | 通过。 |
| 八份相关设计、归档计划和验证文档本地链接检查 | 无缺失路径。 |
| `./scripts/check.sh` | 最终退出码 0；架构/依赖检查、六项 Python 测试、全仓 strict format lint、普通 Swift 测试及独立原生阶段全部通过，工程和四份 plist 校验通过。集成阶段 1,051 项通过（约 64.84 秒），原生运行时阶段 227 项通过（约 206.41 秒）。条件式真实模型/物理设备用例仍按自身开关跳过，不视为实际执行。 |

专项命令：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'writerStreaming|writerCheckpointRevocation|writerCancelledAdmission|writerShutdownJoins|writerCleanupFailure|artifactServiceIsolatesProjectsAndRejectsCrossTaskStreams|writerControlsPreviewAndSearchPaginationAndDraftRecovery|writerBackgroundRoleUsesDirectGatewayAndPublishesActualArtifact'
```

新增回归覆盖：

- sessionID 不匹配、撤销后的 append/complete/工具、取消的 complete、恢复后的旧 streamID 均拒绝。
- 预览挂起期间仍可追加；release/根关闭等待非协作呈现实际退出，再保存最新草稿；并发清理合并。
- start 在途时根关闭等待准入效果，阻止重新开启；start 已取消并回滚后 release 仍能清除撤销围栏，允许正常 resume。
- 检查点在途时第二项变更返回 busy；普通 complete 被撤销，已开始的 abort 不被重复取消；已发生文件效果保留，旧会话不复活。
- 文件系统失败导致 release 错误持续可见，后续准入关闭，重复 release/shutdown 不伪装成功。

## 迭代中遇到的失败

初次直接使用 CommandLineTools 的 swift test 因缺少 metal 编译器失败；后续显式选择已安装的完整 Xcode 工具链。

工作区同期其他改动曾导致 AgentChatWorker 的 modelGenerated 未定义、AssistantChatTests 的嵌套 require 宏、VoiceTests 缺少 rootID，以及工程 Runtime group 悬空引用。对应专项/完整检查当次失败；本次没有覆盖这些文件中的在途改动。它们被工作区后续修改修复后，专项测试及构建通过。早期失败不计作通过。

本地日志：`/tmp/mobileharness-writer-final-tests.log`、`/tmp/mobileharness-writer-final-check.log`、`/tmp/mobileharness-writer-ios.log`。日志为本机会话证据，不纳入仓库或保证长期保留。

## 真机安装（2026-11-06）

按用户要求，将当前工作区的 MobileHarness device scheme 构建并原位安装至已配对的 iPhone 17 Pro。版本为 0.1.0（2026110605），独立设备应用清单确认原版本 2026110604 已更新；安装序号 6128，devicectl 系统启动成功。未执行卸载或数据重置。

签名构建、codesign strict/deep 验证、30 项打包资源及 Live Activity 扩展校验均通过。构建号通过命令行覆盖，不修改本地签名配置或项目版本设置。初次拟用的 2026110601 构建在依赖解析阶段被主动终止，以使用高于手机已装版本的新构建号；该旧编号未安装。

证据：`/tmp/mh-writer-device-build-0605.log`、`/tmp/mh-writer-device-install-0605.json`、`/tmp/mh-writer-device-installed-0605.json`、`/tmp/mh-writer-device-launch-0605.json`。安装和系统启动不等同 Writer 真实模型生成、取消或原生交互验收。
