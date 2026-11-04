# Web — WebKit 页面呈现

WebPageContainer 由 UIContainer 持有，零项目模块依赖。WebPagePresenting 暴露远程/本地加载、观察、截图、前后导航、reload、up/down/top/bottom滚动及关闭；WebPageView 在 Window.web 单实例插槽挂载同一 WKWebView。Root 只组合视图，业务任务与文件由 Actions 拥有。

只接纳 HTTP/HTTPS 远程地址或调用方提供的受控本地入口。本地读取范围默认是入口父目录，宿主可通过 loadLocal(executesScripts:readAccessRoot:) 指定受控版本根以支持嵌套入口及兄弟目录资源；入口必须处于该根内，拒绝越界导航及符号链接；本地配置用 WebKit content rules 阻止 HTTP/WebSocket 子资源。远程与本地切换替换 WKWebView 和非持久化网站数据上下文，不提供特权 JS 桥接，不放宽证书策略或使用私有 API。

单个原生加载，零排队，25秒期限；导航 delegate 完成/失败、取消、进程退出与根失活结束等待。JS观察和截图各有10秒期限及代际围栏；期限到达释放当前原生页面。close 清理导航、代理并释放原生表面，下次访问时按需重建。UI 停止释放页面；窗口最小化取消 Action 工作并卸载可见表面，作品保存寿命独立。

observe 返回有界标题、最多8000 UTF-8字节正文和最多8条/2048字节JS异常；内容只作为不可信观察。snapshot 要求前台可用、加载结束且真实挂载并有尺寸，输出1024像素宽JPEG、最多4MiB；取消或代际变化拒绝迟到截图。加载完成并不保证网络网站全部异步业务已完成，调用方可再次inspect/snapshot验证。

WebPagePolicy 是纯URL校验接口；原生行为需真实WebKit验证，替身不证明加载或截图。

ui.web的Business被动投影content（empty/local/remote）和不超过256 UTF-8字节的远程url；空白/本地页面url为unknown。本地文件路径不披露，available/loading仍属于Runtime。读取State不创建WKWebView、不导航或执行脚本。


WebPageContainer 的根浏览页面保持独立；sessions 按窗口 UUID 持有最多4个创作页面。UI 根按 artifact 窗口选择对应页面。流式本地预览关闭页面脚本，完整检查点才允许执行；根失活传递到全部页面，根停止释放会话。

WebPageContainer 的根页面用于远程浏览；sessions 按窗口 UUID 持有至多四个独立页面，createSession/removeSession/closeSessions 管理生命周期。可用性传播至子页面；loadLocal(executesScripts:) 在导航前设置页面 JavaScript 偏好，供上层区分草稿预览与完整运行。UI 不拥有作品索引、模型或任务。

readAccessRoot 是宿主 URL，不从页面或模型字符串解释；先进行 WebPagePolicy 校验，再以相同根配置导航和 WebKit 读取权限。它不改变业务工作区授权，也不扩大到其他作品。

## 本地 PDF 基础能力

exportLocalPDF 在调用方独立创建的页面中准备受控本地根，设置 A4 宽度并加载完整文档，通过公开 UIPrintPageRenderer/UIGraphicsPDFRenderer 输出分页、可选择文字的 PDF。纸张595.28×841.89点，边距28点；1...100页、最大16MiB，取消在加载、绘制页面边界和完成时检查。本地网络阻断/导航限制继续适用。它不读取作品索引、不创建分享文件、不拥有业务导出队列；完整页面中的脚本可运行，动画只导出当时静态内容。

## 被动多页面状态
ui.web由根WebPageContainer维护根浏览页和按windowID索引的全部sessions摘要。每项提供缓存标题、content、受限远程URL及loading/available；本地URL为unknown。投影只读已有对象，不创建WKWebView、不执行JS或重载，不按调用Agent过滤。窗口的mode/phase/层级仍由唯一WindowState的ui.windows拥有，不在Web重复维护。

根加至多4个会话的观察适配单来源8KiB上限：缓存标题最多128 UTF-8字节，公开远程URL最多256字节，超长字段投影unknown；窗口ID与其余事实继续存在。完整标题/URL/正文仍由显式页面观察接口返回。

新导航/文档更新优先于在途JS观察或截图：显式取消旧native读取，再开始加载，旧回调由token/generation拒绝；导航之间仍busy拒绝，不排队。共享窗口的只读检查不会占住原生查询槽阻断随后创作渲染。该优先级不识别上层Agent身份。
