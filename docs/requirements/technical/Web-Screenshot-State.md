# 网页当前截图接入多模态 State

日期：2026-11-11。用户要求网页截图与相机照片对齐，通过 State 提供给 cognition Agent，只保留当前截图，不提供历史截图。

## 边界与行为

- 保留 browse/snapshot/navigate 的截图触发时机；inspect 只读文本。State 读取不截图、不刷新网页、不触发推理。当前截图指最近一次成功捕获的有效画面，有明确窗口和捕获时间，不代表持续实时采集。
- Actions/Web 的 WebExecutionService 拥有全局单槽内存截图（最多一张分析 JPEG，1 MiB、1568 边长、1 MP）。新捕获替换旧图，开始改变页面或捕获时先失效旧图；失败和取消不恢复旧图。没有历史列表、加载/卸载选择或持久媒体保存。
- 图片绑定实际调用 session 与窗口/页面实例。关闭、最小化、根停止、页面不可用、导航/本地内容修订或可检测的视口变化使旧图失效；跨 scope 不披露。窗口仍可见但切换焦点不抹除明确指向该窗口的截图。新的用户输入可再次看到同一有效截图，无需再次截图。
- UI.WebPagePresenting 暴露只读 snapshotIdentity：页面生命周期/内容版本和视口事实，不依赖 Actions/Agents 或进行 JS/截图调用。截图完成及压缩后验证同一身份；iOS 原生滚动/缩放/尺寸、导航和本地内容更新影响身份。网页后台异步内容没有连续截图观察，需显式新截图更新画面。
- Action 回执保留窗口、URL、标题、文本与诊断，截图结果提供 screenshotID；不再返回可回查历史图片的 mediaID。说明和错误继续由 Actions 代码管理，不新增 Resources/Actions。

## 接口与装配

- 复用 FunctionContracts.ContextImage/MultimodalContextSnapshot。Actions/Web 新增当前截图实现，Service 对外暴露 screenshotSnapshot(scope:) 只读端口；截图压缩由 Actions 装配时注入 PlatformKit 能力，原始字节只存于在途操作。
- ActionsBusinessBindings 与 AgentBusinessBindings 增加窄 readWebScreenshot 端口，App/Composition 透传，不引入反向依赖。AgentRuntime 将其注册为 actions.web.screenshot；WebBrowsing.Skill.useStates 选择该来源。
- 共享 Chat 每轮通过既有 State 图片附件与 system manifest 组装，保持已有五张总上限，超限明确失败，不静默丢图。截图不进入可复用的对话附件或媒体历史；完整模型请求日志沿用相机的实际请求留证（包含当次提交图片），日志不能加载为当前 State。既有容量、历史保护与无图片模型说明机制复用。
- 删除 AssistantWebImagePolicy、网页 feedback 图片观察回调及仅为它提供的 readPhoto 跨模块端口；保留通用 observation 扩展机制。ConversationContext.json 删除不再使用的三个图片说明，保留任务历史模板。清理旧网页图片测试，替换为当前 State 生命周期与真实请求回归。

## 文档与验证

同步 Actions/Web、Actions 根/装配契约、UI/Web、Agents/Assistant/Context/Support、App/Composition、Resources/Skills 与总体设计的当前实现说明；历史迁移证据不改写。新源码/测试只放既有目录，同步 Xcode 引用，不新增目录或模块。

验证单槽替换、重复读取、新用户轮次、scope 隔离、窗口/页面失效、失败/取消/停止与迟到结果围栏、压缩边界、Skill 可见性、无图片模型、对话附件不累积和完整请求留证边界。执行 scripts/check.sh 与 scripts/build-ios.sh，单列真实模型、原生 UI 与真机验收。本次不自动再次安装真机。

## 实施记录

2026-11-12：上述接口、单槽生命周期、Skill State 选择和旧桥接清理已实现。相关技术 README 已同步；构建、定向回归、完整检查的既有时序失败和原生/真机边界见 [验证记录](../../validation/Web-Screenshot-State.md)。完整请求日志沿用现有 Camera 留证，不提供截图历史选择。
