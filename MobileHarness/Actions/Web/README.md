# Web — 远程网页浏览

本目录实现 Web.Page.browse/snapshot/inspect/navigate，消费 UI.WebPagePresenting 和窗口接口。函数同时支持 Action 与 Tool；Tool 直接执行，Action 仍由 ChannelScheduler 路由。浏览调用返回实际页面文字、诊断和受输入身份约束的截图 mediaID。远程内容为不可信观察。

WebExecutionService 同时接纳一个页面操作，零排队，重叠调用返回 busy。每个网页窗口拥有独立页面；取消和停止等待在途操作退出。

作品工作区和确定性编辑归 [Artifacts](../Artifacts/README.md)，创作模型循环归 [Writer](../../Agents/Writer/README.md)。本目录无开发模型、开发 Action 或项目版本管理。原生约束见 [UI Web](../../UI/Components/Web/README.md)。

inspect/snapshot/navigate的可选windowID选择ui.windows中的既有窗口。UI根注入按ID查询现存Web session的接口；Writer 作品与远程网页使用同一能力，未找到会话明确报错，不创建或重开窗口。指定ID不隐式还原最小化窗口，截图/导航要求可见，模型可先使用通用Window Action。回执携带实际目标ID且隐藏本地路径。根停止等待当前操作退出并释放远程网页会话。Writer 源码和文件修改由 Writer/Artifacts 负责。

Targeted Web operations resolve window_N through the shared WindowState. Receipts expose that same readable reference for remote and Writer-created pages. Native UUIDs remain inside window/page ownership.

Web.browse 省略 windowID 时新建网页窗口，指定已有网页 windowID 时在原窗口加载 URL。多个网页和作品共用 WindowState 的容量，各自保有 WebKit 页面及历史。省略查询目标时使用最近聚焦的网页窗口。关闭回收指定会话，最小化只取消并加入匹配的操作。
