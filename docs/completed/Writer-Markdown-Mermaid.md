# Writer Markdown 与 Mermaid 渲染

作品窗口、历史文件预览及 PDF 使用同一个离线文档转换。Actions.Artifacts 保留文件、窗口和导出编排，替换 ArtifactTextRendering 的简化 Markdown 解析。UI.Components.Web 提供通用 Markdown 到静态 HTML 的能力，使用 SwiftPM UI 资源打包 markdown-it 和 Mermaid 的固定版本及许可证。现有目录可容纳 Swift、HTML、脚本和许可证。

markdown-it 解析 CommonMark 和表格、删除线等扩展。保留原生 HTML 转义和 HTTP(S) 链接规则。Mermaid 围栏在独立、短寿命的 WebKit 文档按顺序生成 SVG。宿主只读 UI 包资源，禁用网络，使用 Mermaid 严格模式，屏蔽图表内配置覆盖。文档仅带有图像形式的静态 SVG，作品窗口的增量预览继续禁用页面脚本。单次文档转换沿用加载与调用期限，各调用由现有窗口、历史预览和导出操作约束，无新增等待队列。取消或超时关闭专用页面。

一张图语法错误或超限时保留可读的围栏源码并显示原因。作品渲染回执带图表诊断，其他图和正文仍可展示。库加载失败和调用失败显式传播。现有 Markdown 源码、工作区和源文件导出无需迁移。同步 UI Web、Actions Artifacts、总体渲染设计和第三方许可文档。

验证覆盖中文流程图、多图、普通代码块、无效图、Markdown 表格和嵌套列表、原生 HTML 转义、离线 SVG 产物及作品窗口使用的预览路径。执行 scripts/check.sh 与 scripts/build-ios.sh。iOS PDF 与真机交互的实际验证分别记录。

## 2026-11-09 验证

- macOS WebKit 测试覆盖中文流程图和时序图、无效图回退、普通代码块、表格、嵌套列表和安全转义。作品窗口在增量预览和完整加载中均能解码内嵌 SVG。Writer 文件编辑 Skill 说明 Markdown 图表使用 Mermaid 围栏。
- scripts/check.sh 退出 0，主集成套件 1108 项和 LiveRuntimeTests 229 项通过。原生相机 Metal 用例仅有启动记录。
- scripts/build-ios.sh 退出 0，四个 iOS 模拟器方案及 34 项 Agent/Skill 资源和 Live Activity 校验通过。主 App 包中两套离线库、宿主、适配脚本和许可证与源码资源一致。iOS PDF 实际导出与真机交互待验收。

## 2026-11-09 真机安装

Mobile Harness Debug `0.1.0 (2026110906)` 的严格签名、六项离线 Markdown 渲染资源、34 项 Agent/Skill 资源和 Live Activity 校验通过。已覆盖安装到 iPhone 17 Pro，回执序号 6440。独立查询设备应用清单确认构建号由 `2026110905` 更新为 `2026110906`。证据覆盖安装和版本核对。
