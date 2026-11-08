# Writer 任务与请求详情验证

2026-11-08；范围见[需求](../completed/Writer-Record-Detail.md)。

## 验证范围

- 任务展示仅含开始/更新时间、执行轮数；移除任务级最新执行状态和累计执行时长；文件浏览保留，记录导出位于右上角。
- 请求详情分开呈现当前文本/工具输入、文本回复、工具参数和结果；Prompts 共用 Assistant 的格式化列表，Generation Meta 位于最后。
- 清日志后显示 `Logs cleared`，隐藏 Prompts、Meta、删除按钮，保留本轮输入、回复和工具结果。
- SQLite 重开及清日志测试检查本轮工具输入保留调用 ID/名称/结果；图片仍仅存在日志中。

## 自动化证据

专项测试通过：5 个 UI 呈现测试（协议工具配对用例覆盖 3 种格式）及 2 个 Writer SQLite 集成测试。日志：`/tmp/mobileharness-writer-detail-focused3.log`，退出码 0。

`./scripts/check.sh` 退出码 0，日志 `/tmp/mobileharness-writer-detail-check.log`：格式、模块边界、6 项 Python 测试及 plist 检查通过；包括 1,086 项 Integration、201 项 UI、175 项 AppWorkflow、227 项 LiveRuntime 测试通过。NativePresentationTests 日志启动了 cameraNativeMetalDrawStopAndLayerHandoff，但未报告整个 suite 完成，因此不作为完整原生呈现验收证据。

`./scripts/build-ios.sh` 退出码 0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个构建通过，主应用 Agent 资源和 Live Activity 验证通过。日志：`/tmp/mobileharness-writer-detail-ios.log`。`git diff --check` 通过。

首次聚焦用例发现新 UI fixture 缺少必填 historyOrder，已补齐。后续编译发现当前工作树 Writer library 测试把字符串传给 ActionIdentifier，已改为类型化标识构造；未修改该功能业务实现。

## 验证边界

本次未调用真实云模型，未执行 iOS 原生页面验收，未安装真机。已调整 WriterRecordsNativeAcceptance 中更新时间和展开文本的断言；该脚本不因 Swift 测试或构建通过而算作原生验收通过。

## 真机安装请求（2026-11-08）

用户要求安装最新版本。目标为已连接的 iPhone 17 Pro；安装前应用版本 0.1.0 / 2026110801。复用现有本地签名，构建 2026110802，校验签名及资源后覆盖安装并验证系统启动。保留现有数据；本次不修改业务代码。安装与启动证据不代替页面交互或真实模型验收。

安装结果：

- 签名 Debug 真机构建 0.1.0 / 2026110802 成功；codesign 严格校验、28 项 Agent/Skill 资源和 Live Activity 打包校验通过。构建日志：`/tmp/mobileharness-writer-detail-device-build.log`。
- 覆盖安装成功，安装序列 6320；独立应用清单确认 dev.mobileharness.app / 2026110802。未卸载、清空数据或修改 Provider 凭据。证据：`/tmp/mobileharness-writer-detail-device-install.json`、`/tmp/mobileharness-writer-detail-device-after.json`。
- 正常启动成功，进程清单确认新安装路径的 MobileHarness 进程运行，PID 24501。证据：`/tmp/mobileharness-writer-detail-device-launch.json`、`/tmp/mobileharness-writer-detail-device-processes.json`。
- 以上确认安装与系统启动；未操作 Writer 页面、清除真实日志或调用真实云模型，不作为这些交互的验收结果。

## 真机截图反馈修正（2026-11-08）

- 只读核查真机数据库副本：64 条凌晨 01:25–02:37 的历史消息没有 States 字段；10:29–10:30 的 7 条新消息均有已选路径。用户随后确认新请求已有 States；本次保持状态记录链路和旧数据不变。
- Writer 实际 tool_catalog_json 存放目录条目，旧投影却读取字符串数组，输入 checkpoint 还有第二条写入路径。修正为每轮 request decisionMetadata.catalogJSON 内 tools 的唯一业务目录链路，Request Input 中显示工具集合，清日志后保留。
- Assistant 四项业务内容合并一个 Section；Writer Content 默认收起，输入继续展开。均修改现有文件，无新增源码文件、表或列。
- 专项回归 `/tmp/mobileharness-detail-feedback-focused2.log` 退出 0：2 项 UI 呈现回归、Writer 目录/输入 SQLite 往返回归和既有 Assistant State 持久化回归通过。覆盖输入独立 checkpoint、单条详情、空工具集合、解析错误及清日志后的目录保留。
- 首次专项编译因测试断言宏内缺少显式 try 失败；修正测试表达式后通过，未修改业务错误处理以绕过断言。
- 完整检查 `./scripts/check.sh` 退出 0，日志 `/tmp/mobileharness-detail-feedback-check.log`：1,086 项 Integration、202 项 UI、175 项 AppWorkflow、227 项 LiveRuntime 测试通过，格式、模块边界、Python 和 plist 检查通过。NativePresentationTests 仍未报告整套结束，不记为完整原生验收。
- `./scripts/build-ios.sh` 退出 0，四个目标均 BUILD SUCCEEDED；主应用 Agent 资源和 Live Activity 校验通过。日志 `/tmp/mobileharness-detail-feedback-ios.log`。`git diff --check` 与文档引用检查通过。
- 本轮仅做真机数据只读核查，未安装修正版、未执行原生页面交互验收。现有 WriterRecordsNativeAcceptance 已恢复默认收起/点击展开断言。

## 截图反馈修正版真机安装（2026-11-08）

用户要求安装修正版。目标为已连接的 iPhone 17 Pro，现有版本 0.1.0 / 2026110802。使用现有签名构建 2026110803，验证签名与打包资源后覆盖安装并核对版本和系统启动。保留现有数据，不修改业务代码；安装与启动不代替详情页交互验收。

安装结果：签名 Debug 真机构建 0.1.0 / 2026110803 成功，codesign 严格校验、28 项 Agent/Skill 资源及 Live Activity 校验通过。覆盖安装成功（序列 6328），独立应用清单确认版本 2026110803。正常启动成功，进程清单确认新安装路径下 PID 24580 运行；未卸载或清空数据。证据为 `/tmp/mobileharness-detail-feedback-device-build.log` 及同前缀的 `install.json`、`after.json`、`launch.json`、`processes.json`。本次确认安装和系统启动，未代替详情页点击、日志删除及真实模型交互验收。

## Content 文件条目（2026-11-08）

Content 使用每轮已有的 producerMetadata.path 显示文件图标和完整相对路径，默认收起；缺少路径的普通文本保留 Text 标题。展示仍是当轮保存的回复，不读取实时工作区，也不猜测或合并其他轮次文件。UI 清日志副本保留该业务元数据，无新增数据库字段或源码文件。

专项日志 `/tmp/mobileharness-content-files-focused.log` 退出 0，其中既有 Writer SQLite 往返用例和清日志业务保留用例验证了文件路径经展示 DTO 传递、数据库重开及清日志后保留。完整检查 `./scripts/check.sh` 退出 0，日志 `/tmp/mobileharness-content-files-check.log`：1,086 项 Integration、202 项 UI、175 项 AppWorkflow、227 项 LiveRuntime 以及格式/边界/Python/plist 检查通过。NativePresentationTests 仍无整套完成证据。`./scripts/build-ios.sh` 退出 0，四个目标及主应用资源/Live Activity 校验通过，日志 `/tmp/mobileharness-content-files-ios.log`。差异格式和文档引用校验通过。原生验收断言增加文件名检查，本轮未执行原生页面验收或安装真机。

## Content 文件条目真机安装（2026-11-08）

用户要求安装最新版本。目标为已连接的 iPhone 17 Pro，安装前版本 0.1.0 / 2026110803。计划使用现有签名构建 2026110804，校验后覆盖安装，核对版本并启动应用。保留现有数据，不修改业务代码；安装启动结果与文件折叠交互验收分开记录。

安装结果：签名 Debug 真机构建 0.1.0 / 2026110804 成功；codesign 严格校验、28 项 Agent/Skill 资源和 Live Activity 校验通过。覆盖安装成功（序列 6336），独立应用清单确认版本 2026110804。启动成功，进程清单确认新安装路径下 PID 24632 运行；未卸载或清空数据。证据为 `/tmp/mobileharness-content-files-device-build.log` 及同前缀的 `install.json`、`after.json`、`launch.json`、`processes.json`。以上确认安装与系统启动，不替代文件项展开/收起的真机交互验收。

## 五区块请求详情（2026-11-08）

- Writer 专项四项通过。覆盖草稿反馈摘要、清日志保留业务证据、稳定来源请求、当前调用的模型参数，以及数据库重开后的宿主收尾成功和失败。日志为 `/tmp/mobileharness-writer-layout-focused.log`。
- `./scripts/check.sh` 退出 0。格式、边界、Python 和 plist 检查通过，包含 1,092 项 Integration、203 项 UI、175 项 AppWorkflow 和 227 项 LiveRuntime 通过。NativePresentationTests 日志启动了测试，未报告该套件完成。日志为 `/tmp/mobileharness-writer-layout-check.log`。
- `./scripts/build-ios.sh` 退出 0。四个 Simulator 目标及主应用资源和 Live Activity 校验通过。日志为 `/tmp/mobileharness-writer-layout-ios.log`。
- iPhone 17 Pro 隔离模拟器在首次启动的 KeychainMigrator 阶段等待超过五分钟，退出时报告 Mach -308。测试未进入应用，Writer 点击验收未执行。日志为 `/tmp/mobileharness-writer-layout-native.log`。本轮未安装真机或调用真实模型。

## 五区块请求详情真机安装（2026-11-08）

目标为已配对的 iPhone 17 Pro，安装前为 0.1.0 / 2026110804。使用现有本地签名构建 2026110805，校验签名及资源，覆盖安装并核对版本和启动状态。

签名 Debug 构建 0.1.0 / 2026110805 通过，严格签名、30 项 Agent/Skill 资源和 Live Activity 打包校验通过。覆盖安装成功，安装序列 6344，独立应用清单核对构建号 2026110805。系统启动成功，进程清单核对新安装路径及 PID 24916。覆盖安装保留应用数据。证据为 `/tmp/mobileharness-writer-layout-device-build.log` 及同前缀的 `install.json`、`after.json`、`launch.json` 和 `processes.json`。本次验证范围为安装、版本和启动。
