# 多 Provider 管理验证

2026-10-24。本次范围为 URL 唯一的 provider 列表、单选、编辑、删除与添加，保存后全局应用，凭据使用原钥匙串端口。旧 version=1 单配置文档兼容读取，新增 providers 字段保存完整列表。

验证进行中：scripts/check.sh、scripts/build-ios.sh 和 iPhone 18 Pro / iOS 27 模拟器。自动化使用虚构 URL/Key，不代表真实服务验收。真实网络、错误 Key、断网及在途真实请求验证尚未执行。

## 已取得证据

- `scripts/build-ios.sh` 四个目标全部 BUILD SUCCEEDED，应用资源校验通过。
- 新增 `multipleProvidersSurviveReopenAndDeletionWithoutPlaintextKeys` 通过：两个 URL/Key 配置重开恢复，删除后不自动选其他项，普通文档无明文 Key，旧凭据清理。
- 新增 `providerRestorePreservesMultipleProvidersAndRejectsLateResults` 通过：恢复列表与选择，拒绝旧 revision 的恢复结果。
- `git diff --check` 通过；完整 `scripts/check.sh` 通过（含常规与原生运行时两阶段、格式检查和项目 plist 校验）；最终 UI 调整后 MobileHarnessSimulator 单独重建再次 BUILD SUCCEEDED。

## 模拟器限制

iPhone 18 Pro / iOS 27 已启动，构建应用成功安装并首次启动、显示原生首页；随后准备阶段报 provider.keychain。securityd 明确记录 -34018：脚本的 CODE_SIGNING_ALLOWED=NO 产物缺少 application-identifier / keychain-access-groups。仅在本地构建产物补签后重新安装，系统返回 NSPOSIXErrorDomain 3 / FBSOpenApplicationServiceErrorDomain 3，重启模拟器仍无法启动。未修改仓库签名配置，未以明文凭据回退绕过错误。

当前环境没有 Simulator.app；桌面工具未找到模拟器应用，Device Hub 访问超时。未完成列表增删改选的原生点击与重启验收，不将构建、截图或状态替身测试写成该验收通过。真实服务、错误 Key、断网与真实在途请求切换仍待用户授权服务配置和可交互运行环境。

## 真机安装

2026-10-24：用户要求安装真机。使用现有本地签名配置构建 MobileHarness / Debug 到 build/DeviceDerivedData，BUILD SUCCEEDED；严格深层签名与 25 项 Agent/Skill 资源校验通过。覆盖安装到 Youwei’s iPhone 17 Pro，保留应用数据；首次安装遭遇 CoreDevice 3002 / remote connect error，重试安装成功（/tmp/provider-device-install-retry.json）。安装结果不代表 Provider 原生交互或真实服务验收通过。

启动尝试被设备锁屏拒绝（CoreDevice 10002 / FBS Locked），未确认真机运行；解锁后可手动打开应用。

## Provider 名称与 modal 表单

2026-10-24：按页面反馈增加持久化 name，旧记录缺字段时以 URL 主机名显示。新增时选择未占用的 Provider N 名称；新增与编辑使用独立 modal 草稿，三字段均支持粘贴，Key 脱敏。取消不修改当前配置；确认校验名称、HTTPS URL、重复 URL、容量和 Key 长度。列表显示名称、单行省略 URL 及编辑/删除图标。

新增 providerModalGeneratesDefaultNamesAndValidatesIndependentDraft 通过；原多 Provider 重开/删除/普通文档无明文 Key 回归改为自定义名称并通过，覆盖名称重开保留。本轮 scripts/check.sh 全部通过（含 221 项原生运行时测试），scripts/build-ios.sh 四目标全部通过。最后补充列表名称单行省略后，模拟器 App 与签名真机 App 再次构建成功，最终深层签名和资源校验通过。最终产物覆盖安装到 iPhone 17 Pro 成功（/tmp/provider-modal-final-install.json），未卸载或清理数据。首次安装连接失败后重试成功。这些结果不代替原生 modal 点击、键盘和剪贴板验收。

## HTTP 与 HTTPS / IP 服务

2026-10-24：用户明确要求 HTTP/HTTPS 均支持 IP 测试服务。表单、私有保存请求、模型发现与 Responses 配置接受两种 scheme，不自动升级 HTTP。iOS AppInfo.plist 放行用户自定义 HTTP 服务并声明局域网用途；最终签名设备包已解析验证 NSAllowsArbitraryLoads=true、无覆盖该值的 NSAllowsLocalNetworking 且含 NSLocalNetworkUsageDescription。实现参考 [Apple ATS 配置](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads)。

新增三个回归均通过：providerModalAcceptsHTTPAndHTTPSIPAddresses（含 IPv6/端口/路径与拒绝 FTP）、providerSettingsStagesHTTPIPConfiguration、providerAcceptsHTTPAndHTTPSIPAddressesWithoutChangingRequestScheme。测试使用虚构配置和请求编码，不请求用户 IP 服务。真机签名构建、最终资源/签名校验通过，覆盖安装 iPhone 17 Pro 成功（/tmp/provider-http-install.json）。scripts/check.sh 完整通过（含 221 项原生运行时测试），scripts/build-ios.sh 四目标均 BUILD SUCCEEDED，git diff --check 通过；真实局域网授权、IP 服务连通及模型请求仍需用户配置服务后验收。

## Ollama gpt-oss:20b reasoning summary compatibility

2026-10-24: The user supplied http://192.168.3.177:11434/v1/models and gpt-oss:20b. GET /v1/models confirmed the model exists. A synthetic /v1/responses request completed and emitted response.reasoning_summary_text.delta/done, matching the screenshot failure at unsupportedOutput/event/type in the previous decoder. The provider base URL is http://192.168.3.177:11434/v1; /models is the discovery endpoint.

The fix validates and filters known reasoning summary text/part events without publishing them as answer text or native calls. Existing event/stream bounds, tool pairing, terminal/usage validation and rejection of unknown events remain. No protocol switch, disabled reasoning or automatic request replay. Reference: [Ollama Responses support](https://github.com/ollama/ollama/blob/main/docs/api/openai-compatibility.mdx).

Explicit liveOllamaResponsesReasoningCompatibility passed against the real service/model: plain OK answer, one synthetic Read.State native call through production name/terminal validation, then an OK continuation after a synthetic tool receipt. No device effects or user history/photos/credentials were sent. Together with offline summary validation/malformed index/part/truncation and native-index regression, all three selected tests passed (/tmp/ollama-fix-live2.log). An initial compile error in the added live test's argument order was corrected before this successful run. Four simulator schemes and the signed physical-device build passed. Final packaged resources and strict/deep signature verification passed. Installation on the iPhone 17 Pro succeeded (/tmp/ollama-fix-install.json), retaining data. Automatic launch was denied because the device was locked (/tmp/ollama-fix-launch.json). Full scripts/check.sh passed, including 221 native runtime tests, format/boundary checks and project plist validation; git diff --check passed. Native iPhone interaction and real user tasks require separate acceptance.

## Optional provider URL

2026-10-25: Blank or whitespace-only URL input now resolves to the official https://api.openai.com/v1 endpoint on modal confirmation. The name/key remain unchanged. Explicit and implicit official endpoints share duplicate detection; editing the existing official provider with a blank URL is allowed. The form labels URL optional and explains the default. Added blankProviderURLResolvesToOpenAIDefaultAndPreventsDuplicates. All four simulator builds and the signed physical-device build passed; final resource and strict/deep signature checks passed. Installed on iPhone 17 Pro with data preserved (/tmp/provider-empty-install.json). Full scripts/check.sh passed (including 221 native runtime tests), as did git diff --check. No real OpenAI request was made for this change.

## 智能体大脑与独立模型（2026-11-03）

设置入口和页面改名“智能体大脑”。Provider 管理列表只展示名称/URL，末行添加，原生 swipeActions 编辑/删除；下方 Assistant/Writer 分别选择 Provider/模型，本地选项隐藏模型菜单，最后本地模型资源。进入页面自动刷新已选服务，模型列表按 Provider ID 缓存，保存选择不会被列表刷新清空。

复用旧配置/钥匙串：Assistant 保留 cloud 兼容投影，Writer 使用已有独立字段；Writer 选择本地不继承 Assistant 云端。编辑稳定身份、删除清理双方引用、旧凭据请求迟到不覆盖新列表。删除了全局模型列表及旧发现结果呈现旁路，发现返回值由表单控制器按 Provider 投影。查询有界、离页取消、根关闭加入。

思考策略由 Actions 按角色选择，ModelKit 适配 minimum/enabled；最低策略对不支持关闭的已知模型采用支持的最小档，不再一概拒绝。启用推理时兼容移除不支持的 temperature。参考 [OpenAI reasoning](https://developers.openai.com/api/docs/guides/reasoning)、[deployment compatibility](https://developers.openai.com/api/docs/guides/deployment-checklist)、[Alibaba thinking](https://www.alibabacloud.com/help/en/model-studio/deep-thinking.md)。未知服务/别名的具体能力不伪造，失败不自动重试。

本地 Writer 选项有独立租约路径，但当前 Gemma4Chat 不支持 native tools；页面明确说明此限制，不能将选择本地等同于 Writer 可以执行创作。模拟器也不具备真实 Gemma CoreAI 能力。本轮没有修改 Gemma 工具协议。

- scripts/check.sh 通过（/tmp/agent-brain-check.log）：993 项 IntegrationTests、155 项 AppWorkflowTests、225 项 LiveRuntimeTests，以及其他目标、格式、模块边界、Python/plist。
- 清理旧列表后的定向测试通过（/tmp/agent-brain-final-focused.log）：37 项集成、7 项表单工作流及相关参数测试。覆盖独立配置/文档恢复、Writer 本地不继承 Assistant、乱序发现、编辑凭据隔离、删除引用、取消加入，以及实际思考请求 JSON。
- 首轮开发编译曾因 OS 可用性保护、嵌套测试宏和已移除初始化参数失败，均已修正。旧发现测试曾期待查询直接覆盖全局列表，现按新的 Provider 隔离契约检查返回值且不改写其他选择。
- 首轮 scripts/build-ios.sh 四目标通过（/tmp/agent-brain-ios.log），最终清理后的构建另记。
- 尝试通过电脑工具访问 Simulator 及其完整应用路径均返回 Invalid app；未完成新页面原生目测、滑动/菜单交互或真实 Provider 请求验收。本轮不安装真机、不读取或写入真实凭据、不提交代码。

最终清理后的 scripts/build-ios.sh 四目标全部通过（/tmp/agent-brain-ios-final.log），Agent/Skill 与 Live Activity 资源校验通过。根容器与旧 revision 呈现回归补测通过（/tmp/agent-brain-ui-regression.log，8 项 LiveRuntimeTests + 1 项表单呈现）。git diff --check 通过；源码保持未提交。

### 智能体大脑版本真机安装（2026-11-03）

按用户要求，用现有签名配置构建当前工作区 MobileHarness Debug 成功（/tmp/agent-brain-device-build.log）；30 项 Agent/Skill 及 Live Activity 打包校验通过。已覆盖安装至 Youwei’s iPhone 17 Pro（dev.mobileharness.app，安装序号 5724，/tmp/agent-brain-device-install.log），未卸载或清除数据。devicectl 启动成功（/tmp/agent-brain-device-launch.log）。安装/启动不等同于页面交互、真实 Provider 或 Writer 模型验收。

### 设置删除确认与保存 Toast（2026-11-03）

Provider 删除使用原生 alert，取消不修改草稿，确认使用弹窗捕获的 Provider ID。保存等待实际 Bool 回执，成功显示3秒 Toast，失败显示实际错误6秒；恢复失败也显示 Toast。移除常驻保存状态行，保留按钮忙态与根拥有的保存操作。

验证：`scripts/check.sh` 退出0（日志 `/tmp/settings-feedback-check.log`）；`scripts/build-ios.sh` 四个目标成功、退出0（`/tmp/settings-feedback-build.log`）；`git diff --check` 通过。本次尚未重新安装真机，弹窗与 Toast 的原生交互尚待真机验收。
