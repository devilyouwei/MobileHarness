# Decision 执行日志修复

## 范围与计划

按当前 AssistantDecisionProtocol 校验数字映射：1 interrupt、2 discard、3 enqueue、4 continue_listening；Tool 直接采用 action。保留 Assistant 的采用策略，不把模型 discard 被保留策略改为 enqueue 当作解码错误。

- AssistantInputDecision.swift 在单次分类中保存模型身份，向 InputDecisionOutcome 和 UI 日志投影传递。本地包含 D3 Edge、D3 Lite、Gemma 4 E2B、Apple System LLM；云端使用实际 ChatModel.modelName。失败保留已知模型身份，未解析时不猜测。
- RuntimeLogState.swift 提供独立 modelName 字段，路由只区分 Local、Cloud Decision、Fallback；RuntimeLogView.swift 分别标注最终采用结果与模型结果（无有效结果明确显示），保留调整原因及请求详情。
- 更新 Assistant 与 RuntimeLog README；模块边界不变，UI 不查询模型配置、不解码模型输出。
- IntegrationTests 覆盖模型身份、失败保留、四类结果投影；运行 check.sh 和 build-ios.sh，记录实际结果。真实模型与真机 UI 验收独立记录。

## 追加设置界面范围

用户追加两项布局调整：SettingsView 的本地模型菜单只显示名称（保留不可用提示），移除菜单专用评分拼接；选中模型下方独立 Mac 评分行保留。ModelResourcesView 的 Chat／Decision 标签置于名称前，同一 HStack 按 center 对齐，Apple 系统模型采用相同布局。更新 Settings README。只改变布局，不改变选择、下载、评分数据或可用性逻辑。

## 最新代码与真机交付

用户要求拉取最新代码并安装真机。2026-11-15 将 main 从 1fcf1260 快进到 db614c96，保留本次界面修改和已有本地签名修改；远端 D3 Lite 图兼容改动与本次文件没有冲突。使用 MobileHarness 设备 scheme 构建并原位安装至已配对 iPhone 17 Pro，不卸载、不清空数据。安装后核对设备应用清单；安装成功不代表真实模型或界面验收通过。

## 实施与验证结果（2026-11-15）

日志与两项设置布局调整均已实现，当前设计见 Assistant、RuntimeLog、Settings README。模型身份随本次分类传递；无有效模型结果明确显示；数字协议与采用策略保持不变。

- 拉取：main 快进到 db614c96；工作区界面修改与原有 project.pbxproj 本地签名设置保留，未提交。
- 本次修改文件 Swift format lint 和 git diff --check 通过。
- 签名设备构建：MobileHarness Debug，完整 Xcode，exit 0 / BUILD SUCCEEDED。日志 `/tmp/mobileharness-latest-device-build.log`。
- 最终包：73 项 Agent/Skill 资源、Live Activity、英文/简体中文资源校验通过；codesign --verify --deep --strict 通过。
- 真机：原位安装至 iPhone 17 Pro 成功，安装序号 7108；设备应用清单确认 dev.mobileharness.app，版本 0.1.0 / build 1；系统启动成功。证据 `/tmp/mobileharness-latest-device-{install,app,launch}.json`。未卸载或清空应用数据。
- 前一轮 check.sh 与 build-ios.sh 被用户中断，未获得完整最终结果；不能记为全量通过。中断前观察到边界、Python 测试与格式检查通过，部分 Simulator scheme 构建通过。
- 仍需完成全量自动化最终结果，以及真机日志、菜单和标签的视觉验收；安装和启动不等同于真实模型或原生 UI 功能验收。
