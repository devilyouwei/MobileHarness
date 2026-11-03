# WebKit 浏览与本地绘图 Action

## 目标与范围

在 `codex/webkit-actions` 实现远程网页浏览、截图观察，以及由独立模型请求驱动的 HTML/CSS/JS 工作区开发。主 Assistant 只提交文字任务与工作区身份，不承载生成代码。用户授权本任务自主实施、必要目录及模拟器验证；不创建新一级模块，不新增模型配置或密钥，沿用 Assistant 当前 ModelKit.language 配置。

## 实施前设计

- UI/Components/Web：独立 WebKit 子能力，根生命周期拥有页面会话；公共端口负责远程/受控本地加载、导航、截图与可见状态。接入现有 Window 内容插槽，网页不获得原生桥接权限。远程和本地上下文隔离；本地读取权限仅限该工作区已发布版本。UI 不依赖其他基础模块。
- Actions/Web：业务服务、函数声明、模型编辑循环与工作区版本管理。浏览、截图、导航、创建/继续绘图、打开/列举工作区为明确 Action。模型内部工具提供 list/read/create/唯一文本替换/delete/render/finish；不提供 shell。有限步数、文本/文件/项目容量，拒绝并发写入，取消加入模型请求和渲染，失败不伪造成功。
- Storage/Files：增加独立工作区命名空间，复用受控目录和不可变发布机制。Actions 拥有内容、版本与保留策略，Storage 拥有文件路径及读写。发布整份不可变版本后切换引用，局部修改在内存草稿中验证唯一匹配，保存和渲染失败分别报告。
- ModelKit：直接消费现有 ChatCapability，以独立 InferenceContext/会话调用当前模型；每次编辑可连续请求，内部工具结果反馈给该上下文。不得向主 Assistant 泄漏代码或私有推理。
- 截图结果：沿用中立 Action 结果与 Assistant 图像观察机制，加入可识别且受作用域约束的网页截图引用；不得将未挂载/未完成加载的画面声明为成功。
- App/Composition、ActionsBusinessAssembly、BehaviorAssembly、CapabilityModules、UIContainer、Root：显式注入能力、注册函数、接入窗口与停止链路；保持既有 target 边界。
- Resources/Skills：增加浏览、网页绘图技能和 Catalog 映射，描述任务参数、项目复用、截图验证、失败与模型不支持图像时的行为。

## 分步交付与验证

1. 检查现有接口与参考 harness；实现可测的受限工作区/编辑协议及回归测试。
2. 实现 WebKit 会话、加载/导航/截图、通用窗口接入与生命周期。
3. 实现内部多轮编辑驱动、公开 Action、截图反馈和完整装配。
4. 补齐 skills、各拥有目录 README、总体跨模块数据流、验证记录。
5. 运行 `scripts/check.sh`、`scripts/build-ios.sh`；在可用模拟器验证真实 WebKit 本地页面、局部更新、动画、远程导航及截图。真实模型测试仅使用可用的既有配置，分别记录替身、真实 WebKit、真实模型证据与限制。

## 参考与选择

- [DeepSeek Harness 字符串编辑器](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/fs/tool-str-replace-editor)：参考读取、创建、唯一字符串替换和编辑后观察的模式，采用独立实现；不移植 shell 或任意磁盘访问。
- [Apple WKWebView 文件加载](https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl(_:allowingreadaccessto:)) 与 [WebKit 公共接口](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.h)：使用公开加载与 snapshot API。

## 交付记录（2026-11-03）

原定功能、清理、文档、完整检查、四项iOS构建及可用模拟器验收已完成。真实模型与物理设备独立验收仍按验证记录跟进，不作为已通过证据。

已实现8项Web Actions、WebKit窗口、受限多文件工作区、独立多轮模型编辑器、截图续轮及两个运行时Skill。真实macOS WebKit与iOS模拟器已验证本地多文件、脚本执行、更新、远程加载和截图；最终自动化与构建结果见[验证记录](../validation/WebKit-Actions.md)。原 [产品需求](../requirements/product/Model-Web-Speech-Plan.md) 的 WebKit 项由本计划细化。

### 验证中收敛

实际接入发现导航后 JS 观察与截图也需要独立期限/取消围栏，纳入 UI 原生操作回执；原生页面按需构造，避免根启动创建 WebKit 进程。截图复用 StorageMedia 的受作用域约束图像存储，不新增 Actions.Camera 业务依赖。

StorageFiles 回归发现 DiskFileStore 的同步 actor `fileURL`/`importFile` 与 FileStore 默认 async 方法存在重载选择歧义，直接 `await disk.fileURL` 落到明确拒绝原生文件的默认实现。将这两个真实磁盘入口改为显式 async witness，保留内部同步文件原子边界，并用持久化工作区重开/版本读取测试验证实际路径。

模拟器发现无 charset 声明的本地中文 HTML 被 WebKit 按旧编码解释。发布 HTML 时写入 UTF-8 BOM，源码草稿仍保留原文本；WebKit 入口读取预算额外容纳3字节。编辑器提示同时要求 charset/viewport。模型支持图像时，render 后将截图反馈到内部编辑请求，保留最多一张当前渲染图；主助手仍只收到最终观察。

截图视觉检查发现 WKSnapshotConfiguration.snapshotWidth 使用点而非最终像素；按窗口屏幕 scale 换算，统一限制输出宽度为1024像素。导航补充 up/down/top/bottom，允许 Assistant 通过逐屏截图分析长网页。项目删除加入持久化待清理标记，磁盘失败可用同一projectID重试，不遗失清理身份。

内部 read 分页按最多2500个字符返回，并明确 returnedCharacters/nextOffset，避免中文/emoji内容经UTF-8反馈预算裁剪后错误跳过剩余字符。文件总容量仍按UTF-8字节验证。唯一替换使用 literal 匹配，不把Unicode规范化等价误当成完全相同的源码。

全仓回归要求同时注册 WebModule 的静态 declarations 与运行时绑定；补齐静态目录后，所有打包Skill可通过同一权威声明展开。UI根索引新增web，对应测试由11更新为12。两项新增Skill概览使基础提示约25.3KiB，基础提示回归预算从25,000明确调整为26,000字节，保留有效能力目录及38,000字节摄影提示上限；不增大模型上下文硬上限。

最终失败路径审查区分草稿编辑错误与发布失败：缺少index.html可反馈给内部模型补齐；发布后的容量、版本冲突等工作区错误直接保留原因返回，不以通用stepLimit覆盖。加入发布容量失败回归。

对照Gemma当前的末尾消息裁剪契约，内部编辑请求把协议、任务与当前文件清单附到最新user观察，而不是只放在首条消息。这样沿用本地模型时，多轮后仍保留当前任务和编辑协议；历史只存原始观察，不重复积累提示词。加入每轮最新消息包含任务的回归。
