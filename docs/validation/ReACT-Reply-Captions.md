# ReACT 回复字幕验证

日期：2026-11-16。

## 范围与方法

`GenerationRoundTests.fullDuplexReACTRepliesReachCaptions` 参数化覆盖 Action 与 native Tool。替身模型先输出“正在处理。”、返回合成的网页观察结果，再生成“已观察真实结果。”；真实 Assistant 工作器、Gateway 与 ConversationPresentation 验证结果输入的轮次、新 Decision、字幕替换，以及迟到旧 Decision 和取消轮次的拒绝。没有访问真实网页、调用真实模型或操作原生字幕 UI。

## 证据

- 修复前定向回归：两种参数均失败，字幕仍为“正在处理。”，只接纳一次 beginReply。
- 修复后首轮定向回归：Action 通过，native Tool 参数仍失败；完整检查内该参数化用例两种参数均通过。添加错误与请求数量断言后定向复查退出 0，两种参数均通过（0.059 秒）；首轮差异原因未证实，不将其改写为通过。
- `./scripts/build-ios.sh`：退出 0；MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero、ModelKitAppleLLM 五个目标均 BUILD SUCCEEDED。
- 修改文件 Swift 格式检查及 `git diff --check` 通过。
- `./scripts/check.sh`：退出 1。边界脚本、8 个 Python 测试与 Swift 格式检查通过。IntegrationTests 的 readyD3ReportsItsSelectionAndDoesNotCallCloud、inputDecisionProtectsPossibleSpeechCommandsFromModelDiscard、slowTrackingDispatchExecutesOnlyTheNewestPendingTarget 失败；AppWorkflowTests 多项 Writer/Web 用例报告 resourceMissing("injected Action declarations")，语音偏好测试的模型列表期望未包含工作区已有的 deepfilternet3，持续无进展后人工终止该测试进程。未修改这些字幕范围外的用例。第二阶段 LiveRuntimeTests 的 228 个测试通过，plist 校验通过；不将这些替身/主机测试视为物理设备验收。
- 首次沙箱内测试/构建被 Swift 缓存写入权限阻止；批准沙箱外运行后正常进入编译与测试。

## 独立真机验收

开启聆听，要求读取网页后回答；确认初始话术后，观察结果触发的 assistant 正文替换下方字幕。继续查询形成多轮观察，检查后续回复仍显示；关闭聆听后旧结果不得恢复字幕。本次未执行此项，不将构建或替身测试视为真机验收。
