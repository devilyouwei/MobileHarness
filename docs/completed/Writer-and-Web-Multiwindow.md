# Writer 批量打开作品与网页多窗口

实施日期为 2026-11-09。

真机 SQLite 只读调查定位到 5 个已保存作品和 1 次最近批量打开请求。查询返回 5 条，执行只打开首件并把委托绑定到单作品 viewer，随后以单件展示完成收尾。数据库 quick_check 通过。修复运行时与工具教学，无需修改真机数据。

- Writer 作品库新增 openAll，保持单作品编辑与查看的绑定契约。Actions 复用受控 catalog 分页和单作品打开流程，顺序尝试，返回逐项窗口身份、状态和失败。批次遇到容量、冲突或缺文件时保留其他已打开窗口，并在回执中提供可读原因。下一页以真实游标显式继续。
- UI WindowState 和 WebPageContainer 共享 12 窗口上限。Writer 作品和网页使用同一 window_N 命名空间。原生状态测试验证公开编号以及内部 UUID 和本地路径隔离。网页改为按 UUID 各自挂载 WebPageContainer，会话相互隔离。Camera 仍使用其固定窗口身份。
- Web.browse 省略 windowID 时新建窗口，指定已有网页 windowID 时在该窗口导航到新 URL。查询和导航省略目标时用最近聚焦的网页。已指定的 Writer 页面只支持现有的观察、截图和窗口内导航。关闭或最小化只加入匹配窗口的 Web 操作，关闭回收对应页面。
- 验证一次打开至少五件现有作品，网页新开两窗及定向跨站跳转，失效身份、独立关闭和容量。执行 check.sh 与 build-ios.sh，记录构建、自动化、设备安装与交互各自的证据范围。

实施与验收证据见[验证记录](../validation/Writer-and-Web-Multiwindow.md)。
