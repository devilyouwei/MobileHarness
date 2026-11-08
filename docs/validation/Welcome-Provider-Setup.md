# Welcome 云端服务配置验证

2026-11-08。范围见[需求](../completed/Welcome-Provider-Setup.md)。

## 自动化证据

- 设置专项回归：使用完整 Xcode 工具链运行 Welcome 与既有设置保存/恢复/发现/停止测试，8 个测试函数全部通过，其中默认/自定义 URL 两种参数。日志：/tmp/mobileharness-welcome-focused2.log。
- 覆盖：恢复前/恢复失败不引导、不覆盖已有 Provider；空 URL 默认 OpenAI、自定义 URL 和 key 修剪；空 key、错误 URL、超长 key 拒绝；保存失败保留空 Provider 状态并可重试；并发保存只接纳一次；停止后不发布新 Provider；重新创建设置控制器后恢复已保存 Provider。
- 首次直接 swift test 使用系统 CommandLineTools，因缺少 metal 工具而未运行测试；指定 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer 后构建及专项回归通过。不是测试失败，也不将首次尝试记为通过。
- 边界检查通过：基础 UI 仍无项目模块依赖，新增表单属于现有 UI target，未新增目录或服务。

## 验收边界

专项测试使用设置操作替身，不使用真实凭据，不请求真实 Provider。未在物理 iPhone 上验证系统 PasteButton 授权、键盘/屏幕布局和重启；构建与自动化结果不代表这些原生交互或真实云端认证已验收。

## 原生验收步骤

1. 无 Provider 的安装启动后出现 Welcome；URL 留空，粘贴测试账户 key，保存后进入模型选择页。
2. 在模型设置页为两侧选择 Provider/模型并保存，重新启动不再弹出 Welcome。
3. 在空配置状态点击“稍后设置”，可进入首页；下一次冷启动仍提示。
4. 自定义 URL 支持粘贴；无效 URL 显示错误且保留密钥输入。模拟保存失败时保持弹窗，重试成功后才进入模型页。
5. 已有 Provider 但 Assistant 仍为本地模型时不弹出；设置读取失败只显示错误和重试，不覆盖已有配置。

## 首次实现的完整检查

- ./scripts/check.sh 退出 0，日志 /tmp/mobileharness-welcome-check.log。1,083 项集成测试、197 项 UI 测试、174 项工作流测试及 227 项 LiveRuntimeTests 均报告通过；其余测试 target、6 项 Python 测试、模块边界、严格 Swift 格式和 plist 校验通过。
- NativePresentationTests 完成两个相机呈现测试后启动 cameraNativeMetalDrawStopAndLayerHandoff，未输出整套完成结果。脚本成功退出不代表完整原生呈现验收；该缺口与 Welcome 真机粘贴/键盘验收一起单独保留，不记为通过。

- 首次实现的 ./scripts/build-ios.sh 退出 0，四个目标均 BUILD SUCCEEDED，日志 /tmp/mobileharness-welcome-ios.log。这次构建先于下述 Writer 独立保存修正，不能代替修正后的最终验证。

## Writer 独立保存回归

代码复核发现：Assistant 保持本地且初始 URL 等于新 Provider URL 时，普通设置保存会将 Assistant 空 key 同步到新 Provider，影响仅为 Writer 选择云端的流程。已将同步限定为 Assistant 已启用云端，并补充 welcomeProviderKeepsItsKeyWhenOnlyWriterUsesCloud，覆盖创建服务 → 只选择 Writer → 保存 → 再恢复。

## 修正后的检查结果

- ./scripts/check.sh 退出 1，日志 /tmp/mobileharness-welcome-check2.log。1,083 项集成测试中只有 slowTrackingDispatchExecutesOnlyTheNewestPendingTarget 在 NexArmAimTests.swift:812 的目标值断言失败；相同用例在此前 Database 检查 /tmp/mobileharness-decoupled-check1.log 中也失败过，后续完整检查及 Welcome 首轮检查通过。本次没有修改该测试或跟踪实现。
- 同次运行的 175 项工作流测试（包含新增 Writer 单独云端保存回归）、197 项 UI 测试、227 项 LiveRuntimeTests 及其它测试 target、模块边界、6 项 Python 测试、严格 Swift 格式和 plist 检查通过。NativePresentationTests 仍缺少完整结束证据，不能记为整套通过。
- 空闲环境单独复测跟踪失败项并复跑设置相关用例，命令退出 0：跟踪用例通过，9 个设置测试函数通过（默认/自定义 URL 含两个参数）。日志 /tmp/mobileharness-welcome-focused3.log。该结果不抹除上述全量并发执行失败；未通过修改设备代码或放宽断言规避问题。

- 最终 ./scripts/build-ios.sh 退出 0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个目标全部 BUILD SUCCEEDED。日志 /tmp/mobileharness-welcome-ios2.log；覆盖 Writer 独立保存修正后的代码。未安装真机或清空用户数据。

## 真机安装请求（2026-11-08）

用户要求安装当前版本。目标为已配对的 Youwei’s iPhone 17 Pro，安装前版本为 0.1.0 / 2026110705。计划复用现有本地签名构建 2026110801，校验签名与打包资源后覆盖安装、核对版本并请求系统启动；本轮不修改业务代码，不需要再次清空数据。实际安装/启动结果与 Welcome 交互验收分开记录。

安装结果：

- 签名 Debug 真机构建 0.1.0 / 2026110801 成功，日志 /tmp/mobileharness-welcome-device-build.log。codesign --verify --deep --strict、30 项 Agent/Skill 资源和 Live Activity 打包校验均通过。
- 在 iPhone 17 Pro 上覆盖安装成功，安装序列 6280；独立应用清单确认 dev.mobileharness.app / 2026110801。未卸载或清空数据，未更改 Provider 凭据。证据：/tmp/mobileharness-welcome-device-install.json、/tmp/mobileharness-welcome-device-after.json。
- 正常启动请求成功，随后进程清单确认新安装路径的 MobileHarness 进程运行，PID 23784。证据：/tmp/mobileharness-welcome-device-launch.json、/tmp/mobileharness-welcome-device-processes.json。
- 以上确认真机构建、安装及系统启动；未操作 Welcome 表单、粘贴真实 key 或调用真实云端模型，交互和认证验收边界保持不变。
