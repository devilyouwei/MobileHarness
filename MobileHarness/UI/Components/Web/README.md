# Web — WebKit 页面呈现

WebPageContainer 由 UIContainer 持有，零项目模块依赖。WebPagePresenting 暴露远程/本地加载、观察、截图、前后导航、reload、up/down/top/bottom滚动及关闭；WebPageView 在 Window.web 单实例插槽挂载同一 WKWebView。Root 只组合视图，业务任务与文件由 Actions 拥有。

只接纳 HTTP/HTTPS 远程地址或调用方提供的受控本地入口。本地读取范围为入口所在版本目录，拒绝越界导航及符号链接；本地配置用 WebKit content rules 阻止 HTTP/WebSocket 子资源。远程与本地切换替换 WKWebView 和非持久化网站数据上下文，不提供特权 JS 桥接，不放宽证书策略或使用私有 API。

单个原生加载，零排队，25秒期限；导航 delegate 完成/失败、取消、进程退出与根失活结束等待。JS观察和截图各有10秒期限及代际围栏；期限到达释放当前原生页面。close 清理导航、代理并释放原生表面，下次访问时按需重建。UI 停止释放页面；窗口最小化取消 Action 工作并卸载可见表面，作品保存寿命独立。

observe 返回有界标题、最多8000 UTF-8字节正文和最多8条/2048字节JS异常；内容只作为不可信观察。snapshot 要求前台可用、加载结束且真实挂载并有尺寸，输出1024像素宽JPEG、最多4MiB；取消或代际变化拒绝迟到截图。加载完成并不保证网络网站全部异步业务已完成，调用方可再次inspect/snapshot验证。

WebPagePolicy 是纯URL校验接口；原生行为需真实WebKit验证，替身不证明加载或截图。

ui.web的Business被动投影content（empty/local/remote）和不超过4096 UTF-8字节的远程url；空白/本地页面url为unknown。本地文件路径不披露，available/loading仍属于Runtime。读取State不创建WKWebView、不导航或执行脚本。
