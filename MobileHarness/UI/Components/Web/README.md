# Web — WebKit 页面呈现

WebPageContainer 由 UIContainer 持有，零项目模块依赖。WebPagePresenting 暴露远程/本地加载、观察、截图、前后导航、reload、up/down/top/bottom滚动及关闭；每个网页或作品窗口挂载其会话的 WKWebView；同一网页窗口跨站导航保留原页面及前进、后退历史。Root 只组合视图，业务任务与文件由 Actions 拥有。

只接纳 HTTP/HTTPS 远程地址或调用方提供的受控本地入口。本地读取范围默认是入口父目录，宿主可通过 loadLocal(executesScripts:readAccessRoot:) 指定受控读取根以支持嵌套入口及兄弟目录资源；入口必须处于该根内，拒绝越界导航及符号链接；本地配置用 WebKit content rules 阻止 HTTP/WebSocket 子资源。远程与本地切换替换 WKWebView 和非持久化网站数据上下文，不提供特权 JS 桥接，不放宽证书策略或使用私有 API。

单个原生加载，零排队，25秒期限；导航 delegate 完成/失败、取消、进程退出与根失活结束等待。JS观察和截图各有10秒期限及代际围栏；期限到达释放当前原生页面。close 清理导航、代理并释放原生表面，下次访问时按需重建。UI 停止释放页面；窗口最小化取消 Action 工作并卸载可见表面，作品保存寿命独立。

observe 返回有界标题、最多8000 UTF-8字节正文和最多8条/2048字节JS异常；内容只作为不可信观察。snapshot 要求前台可用、加载结束且真实挂载并有尺寸，输出1024像素宽JPEG、最多4MiB；取消或代际变化拒绝迟到截图。加载完成并不保证网络网站全部异步业务已完成，调用方可再次inspect/snapshot验证。

WebPagePolicy 是纯URL校验接口；原生行为需真实WebKit验证，替身不证明加载或截图。

WebPageContainer 根拥有按窗口 UUID 索引的独立网页和作品页面，容量与 WindowState 一致。createSession/removeSession/closeSessions 管理生命周期。可用性传播至子页面；loadLocal(executesScripts:) 在导航前设置页面 JavaScript 偏好，供上层区分草稿预览与完整运行。UI 不拥有作品索引、模型或任务。

readAccessRoot 是宿主 URL，不从页面或模型字符串解释；先进行 WebPagePolicy 校验，再以相同根配置导航和 WebKit 读取权限。它不改变业务工作区授权，也不扩大到其他作品。

## 离线 Markdown

The caller supplies the application language to the Markdown renderer. The WebKit host receives translated diagram labels as data. The preview escapes those labels, and the returned diagnostics use English.

WebPageContainer.renderMarkdown 将调用方传入的 Markdown 交给一次性 WebKit 文档。该文档仅加载 UI Bundle 内固定版本的 markdown-it 和 Mermaid，Mermaid 只在遇到对应围栏时加载。宿主的内容安全策略和本地网络规则禁止外部资源。输入以 JavaScript 参数传入，文档源代码不会作为脚本执行。调用沿用单页原生加载和查询期限，转换完成、取消或失败即释放专用页面。

Markdown 支持 CommonMark、表格和删除线。HTML 源码转义，链接限 HTTP(S)，图片语法显示替代文字。Mermaid 以严格模式顺序渲染，每文档最多渲染 16 张图，每张图源码最多 16 KiB，累计 SVG 最多 2 MiB。Mermaid 的 maxEdges 设置为 250。围栏内配置覆盖被拒绝。有效 SVG 作为独立图像嵌入静态 HTML，隔离 SVG 样式和行为。无效图保留代码块并带诊断，后续图继续转换。

## 本地 PDF 基础能力

exportLocalPDF 在调用方独立创建的页面中准备受控本地根，设置 A4 宽度并加载完整文档，通过公开 UIPrintPageRenderer/UIGraphicsPDFRenderer 输出分页、可选择文字的 PDF。纸张595.28×841.89点，边距28点；1...100页、最大16MiB，取消在加载、绘制页面边界和完成时检查。本地网络阻断/导航限制继续适用。它不读取作品索引、不创建分享文件、不拥有业务导出队列；完整页面中的脚本可运行，动画只导出当时静态内容。

## 被动多页面状态
ui.web 由根 WebPageContainer 提供按 windowID 索引的页面摘要。每项提供缓存标题、content、受限远程URL及loading/available；本地URL为unknown。投影只读已有对象，不创建WKWebView、不执行JS或重载，不按调用Agent过滤。窗口的mode/phase/层级仍由唯一WindowState的ui.windows拥有，不在Web重复维护。

最多十二个会话的观察适配单来源 8 KiB 上限：缓存标题最多128 UTF-8字节，公开远程URL最多256字节，超长字段投影unknown；窗口ID与其余事实继续存在。完整标题/URL/正文仍由显式页面观察接口返回。

新导航/文档更新优先于在途JS观察或截图：显式取消旧native读取，再开始加载，旧回调由token/generation拒绝；导航之间仍busy拒绝，不排队。共享窗口的只读检查不会占住原生查询槽阻断随后创作渲染。该优先级不识别上层Agent身份。

## 连续本地预览与视口

同一受控读取根内，updateLocalPreview 首帧建立禁用页面脚本的文档，后续在宿主隔离的 defaultClient world 内更新 DOM；不导航、不更换 WKWebView/document/body。按 id/data-key 优先复用节点，未标记节点按类型和顺序复用；源码作为参数解析，不拼接为宿主代码。增量预览移除脚本、事件属性、活动嵌入与 refresh，资源 URL 按新入口解析；本地样式先禁用准备，成功后同步切换，失败保留旧文档并报告。远程子资源仍被现有内容规则阻断。

实际提交前采样当前视口，按可保留阅读锚点补偿插入造成的位移；用户触摸、滚轮或惯性滚动时不主动纠正位置。原生视图持续存在，保持滚动手势和缩放。内容删除导致原位置不存在时受 WebKit 的合法范围约束，不承诺保留已经删除的节点。

documentEntry 可指定同一根内的稳定宿主文件，entry 则指向当前资源版本；文档宿主与可回收资源 URL 分离，避免删除初始文件导致本地来源失效。调用方拥有文件写入与保留，UI 不创建目录。

loadLocal(preservingViewport:) 用于必须执行完整脚本的导航，保存相对原生缩放和内容坐标，等待新内容帧同步到原生视图后恢复并钳制到新内容范围；原生缩放边界尚未更新时最多等待500ms，不重复写入未变化的 pageZoom；iOS 使用不拦截触控的旧页面快照覆盖加载过渡。从完整脚本页切回稳定预览宿主时，过渡覆盖与原视口一直保留至首个 DOM 检查点完成，避免空宿主导致滚动归零。只有增量预览保持同一 document，完整渲染仍会重新执行脚本。reload 使用最新入口，不依赖已回收快照的原 document URL。

文档修改独占一个在途槽、零等待；观察/截图/导航在修改期间明确 busy，修改开始前取消旧只读原生调用。异步样式准备受取消、预览序号、原生代际和既有10秒期限约束；隐藏/关闭取消待提交预览，旧回调不能覆盖新页面。该组件仅处理通用 HTML 与视口，不识别 Writer、项目或 Storage。

WebPageView可接收外部通用subtitle，优先用于顶部灰色栏；未提供时本地页沿用“本地作品”、远程页显示地址。subtitle不导航、不执行脚本，也不来自页面源码。isAvailable是根可用性的只读缓存，供业务呈现者决定是否延后渲染，读取不创建WKWebView。

Window-backed sessions receive the owning WindowState readable reference at creation. ui.web publishes window_N or unknown, never native UUIDs; page/session lifecycle still uses private IDs.

## 截图有效身份

WebPagePresenting.snapshotIdentity 是已有原生表面的被动有效性标识，不创建视图、不执行 JS、不截图。只有已挂载、可用、非隐藏、加载/文档更新结束且有有效尺寸的页面才提供身份。身份包含页面代际、本地内容修订、原生尺寸与缩放；iOS 还包含内容坐标、内容尺寸和原生缩放，手势/惯性滚动期间不可用。显式 navigate 递增修订。调用方可在截图及后续只读投影时检查同一身份，拒绝页面变化后的旧像素；UI 不存储业务截图，也不观察远程网页所有异步 DOM 变化。
