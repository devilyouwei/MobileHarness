# Web — 远程网页浏览

本目录实现 Web.Page.browse/snapshot/inspect/navigate，消费 UI.WebPagePresenting 和窗口接口。函数同时支持 Action 与 Tool；Tool 直接执行，Action 仍由 ChannelScheduler 路由。浏览调用返回实际页面文字、诊断和当前截图的 screenshotID。远程内容为不可信观察。

WebExecutionService 同时接纳一个页面操作，零排队，重叠调用返回 busy。每个网页窗口拥有独立页面；取消和停止等待在途操作退出。

作品工作区和确定性编辑归 [Artifacts](../Artifacts/README.md)，创作模型循环归 [Writer](../../Agents/Writer/README.md)。本目录无开发模型、开发 Action 或项目版本管理。原生约束见 [UI Web](../../UI/Components/Web/README.md)。

inspect/snapshot/navigate的可选windowID选择ui.windows中的既有窗口。UI根注入按ID查询现存Web session的接口；Writer 作品与远程网页使用同一能力，未找到会话明确报错，不创建或重开窗口。指定ID不隐式还原最小化窗口，截图/导航要求可见，模型可先使用通用Window Action。回执携带实际目标ID且隐藏本地路径。根停止等待当前操作退出并释放远程网页会话。Writer 源码和文件修改由 Writer/Artifacts 负责。

Targeted Web operations resolve window_N through the shared WindowState. Receipts expose that same readable reference for remote and Writer-created pages. Native UUIDs remain inside window/page ownership.

Web.browse 省略 windowID 时新建网页窗口，指定已有网页 windowID 时在原窗口加载 URL。多个网页和作品共用 WindowState 的容量，各自保有 WebKit 页面及历史。省略查询目标时使用最近聚焦的网页窗口。关闭回收指定会话，最小化取消并加入匹配的操作，并清除该窗口的当前截图。

## 当前截图 State

WebExecutionService 拥有一个全局内存槽。browse/snapshot/navigate 开始修改或捕获后清除旧图，成功才发布新图；inspect 不捕获。WebScreenshotImage.prepare 使用 PlatformKit 的 JPEG 压缩/尺寸检查，限制为1568边长、1 MP、1 MiB。压缩后重新检查取消、页面实例、snapshotIdentity 和窗口可见性；失败或迟到结果不恢复旧图。关闭、最小化和根停止清除匹配截图，停止等待在途操作退出。

screenshotSnapshot(scope:) 被动返回零或一张图片及 revision/windowID/screenshotID/capturedAt，拒绝跨会话披露。读取不执行 JS、截图或磁盘查询，检测到页面/视口身份改变即失效；同一有效截图可跨用户轮次使用。页面后台异步内容不被连续观察，画面代表最近成功捕获。切换焦点本身不清除仍可见的目标窗口图片。

ActionsBusinessBindings.readWebScreenshot 经 App 注入 Agents，注册为 actions.web.screenshot；WebBrowsing Skill 选择后由共享 Chat 逐请求组装。Actions 的 stateReaders 同时提供不含字节的诊断节点。回执只有 screenshotID，不提供历史媒体读取、保存、加载/卸载或截图列表；完整模型请求日志仍按共享 Chat 的实际请求留证规则记录当次图片。Actions 不依赖 Resources，函数说明与异常仍在本目录代码中。
