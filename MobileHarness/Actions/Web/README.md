# Web — 远程网页浏览

本目录实现 Web.Page.browse/snapshot/inspect/navigate，消费 UI.WebPagePresenting 和窗口接口。函数同时支持 Action 与 Tool；Tool 直接执行，Action 仍由 ChannelScheduler 路由。浏览调用返回实际页面文字、诊断和受输入身份约束的截图 mediaID。远程内容为不可信观察。

WebExecutionService 拥有单浏览会话、零等待操作队列，重叠拒绝；取消/停止加入工作。浏览窗口关闭释放页面，最小化结束当前浏览操作。

作品工作区和确定性编辑归 [Artifacts](../Artifacts/README.md)，创作模型循环归 [Writer](../../Agents/Writer/README.md)。本目录无开发模型、开发 Action 或项目版本管理。原生约束见 [UI Web](../../UI/Components/Web/README.md)。

inspect/snapshot/navigate的可选windowID选择ui.windows中的既有窗口。UI根注入按ID查询现存Web session的接口；Writer作品与根浏览页使用同一能力，未找到会话明确报错，不创建或重开窗口。指定ID不隐式还原最小化窗口，截图/导航要求可见，模型可先使用通用Window Action。回执携带实际目标ID且隐藏本地路径。浏览根关闭仅取消指向根的操作，不关闭或取消其他作品页面；根停止仍加入当前操作。一次操作、零排队准入不变，Writer源码/文件修改仍归Writer/Artifacts。

Targeted Web operations resolve window_N through the shared WindowState. Receipts expose that same readable reference for remote and Writer-created pages. Native UUIDs remain inside window/page ownership.
