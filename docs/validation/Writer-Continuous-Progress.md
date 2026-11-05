# Writer 快速完成与持续进度验证

日期：2026-11-04。需求及实施契约见[Writer计划](../requirements/Writer-Agent-Plan.md)。本专项记录真实设备调查、持续预览、普通进度合并、自然收尾和请求记录页的证据；不改写此前失败。

## 真机 task_6 基线

只读复制iPhone17 Pro的records.sqlite，immutable读取integrity_check=ok。base快照含task_6完整completed终态；WAL复制发生CoreDevice7000/Socket60超时，没有用失败传输推断更晚状态。调查结束移除临时副本，设备数据库未修改。

目标“绘制一份简单的测试流程图”，约1581.7秒（26分22秒）、34次模型请求；工具为list1/edit6/render5/read12/search7/finish1。首次内容约559.6秒、22746字符，首个render请求在约587.3秒，完成渲染的进度约592秒。首次文件生成期间，进度事实从约27.7秒到587.3秒存在约560秒空档，preview参数均off。

后续修改动画、reduced-motion与损坏样式片段，包含一次readRequired；窗口最小化后连续三次render返回unavailable。真机工具声明尚无本机新增的literal replace。Assistant接收到了started/progress/completed事实，但该快照不能证明实际语音开始/播毕时间。

| 相对开始 | 只读快照中的事实 |
| --- | --- |
| 0 | 接纳简单流程图任务 |
| 约27.7秒 | 内容生成前的最后阶段进度 |
| 约27.7–587.3秒 | 约560秒没有新的阶段进度；首次内容请求耗时约559.6秒 |
| 约587.3秒 | 首个显式render请求 |
| 约592秒 | 完成该次渲染的progress事实 |
| 后续执行 | 反复读取/搜索/修改；最后3次render因窗口最小化返回unavailable |
| 约1581.7秒 | completed终态，共34次实际模型请求 |

时间点表示持久请求/消息证据，不把它们等同屏幕绘制或语音播报的实际时刻。

## 实现与可观测指标

Writer拥有750ms预览worker，一个在途+一个最新待呈现请求，通过内部Gateway preview读取安全检查点；源码接收不等待重载。preview禁脚本，完整render执行脚本，render/finish/abort/生命周期先加入预览，窗口不可见不重开。每个模型attempt持久化身份/phase/attempt/path/累计number后才调用模型；SQLite只在请求边界保存metadata，delta仍在内存中累积。

正常无工具响应进入同一Gateway发布校验，运行时效果存origin=writer.runtime的generationRounds，模型native工具记录不伪造。完成前处理已接纳补充，实际提交期间拒绝迟到补充；renderRequired可修正，提交不确定不重放。

普通进度原始signal与Writer完整请求保留，Assistant只留一项待汇报摘要，等待正式FIFO/播放/peer空闲，间隔至少10秒；追问和终态保持原32项FIFO及持久终态投递。摘要独立输入身份，终态清除未接纳普通摘要。UI以轻量元数据分页/总数/任务时间刷新，完整源码只按需读取；Settings两个入口和详情头部操作独立显示。

## 验证记录

### 自动化与真实模型

完整检查首轮发现两项问题：SQLite合法的空预留身份没有metadata，轻量查询误将其作为JSON解析；预览用例在千项并发运行中未能在测试5秒内获得调度。前者增加空data分支、非空损坏JSON仍报错；后者只放宽测试启动等待至20秒，不改变生产750ms或取消/不重试断言。最终检查结果在下节列出，首轮exit1不改写为通过。

[机器结果](Writer-Continuous-Progress.json)和[逐请求/预览轨迹](Writer-Continuous-Progress-Requests.json)来自一次未变Writer/Artifacts/OpenAI源码与测试二进制的真实矩阵，sourceUnchanged=true、binaryUnchanged=true，两个进程exit0，各6/6通过。使用被忽略的.env.local阿里兼容端点、Qwen3.8-max和实际Provider ID deepseek-v4.1-flash；均thinking enabled、maximumOutputTokens=provider default。没有生产总轮数/任务时限。评估自身保留36请求/600秒显式取消边界，方法及macOS WebKit适配器限制沿用[前次实验](Writer-Model-Regression.md)。

| 流程 | Qwen：秒 / 请求 / 预览帧 | DeepSeek：秒 / 请求 / 预览帧 |
| --- | ---: | ---: |
| 原始目标：绘制一份简单的测试流程图 | 229.6 / 4 / 43 | 92.7 / 11 / 12 |
| HTML/CSS/JS多文件 | 63.3 / 7 / 7 | 22.6 / 9 / 5 |
| 续作局部修改 | 22.0 / 6 / 3 | 7.3 / 6 / 3 |
| 搜索、移动、替换、增删 | 42.0 / 10 / 5 | 16.7 / 11 / 5 |
| Markdown报告 | 46.0 / 4 / 4 | 8.2 / 5 / 2 |
| JS错误后修复与重新render | 55.0 / 8 / 6 | 12.5 / 8 / 5 |
| 整体 | 458.1 / 39 | 160.3 / 50 |

简单流程图没有添加测试专用的“禁止美化”等补充goal；控制/内容请求均使用生产提示词。对照真机task_6的1581.7秒/34请求，这次Qwen229.6秒/4请求，DeepSeek92.7秒/11请求；模型、设备与请求时间不同，属于病例对照，不能据此承诺固定加速比例。以前六例评估中较短的性能数字使用了更具体的流程图提示，不混为同一目标的前后对照。

Qwen首个非准备/空白内容197.29秒，在内容请求结束前约23.83秒；DeepSeek75.86秒，在内容请求结束前约3.65秒。源码预览连续更新的中位间隔分别0.803/0.805秒，最大1.54/10.15秒；后者含确定性修改后预览，不代表750ms定时器保证。预览会合并，没变的检查点不重载。表中previewFrames是原始preview调用数，含启动占位/尚无正文的安全检查点；firstVisible单独排除占位/空白，不将它们计为有效画面。

Qwen内容首事件等待148.56秒、内容请求183.02秒；DeepSeek47.43/55.41秒。模型未返回源码前无法生成真实画面，当前仍存在显著Provider/模型等待，不能宣称“立即看到图”。两模型这项任务均没有增加动画/交互面板；Qwen没有后续编辑，DeepSeek存在一次4px箭头端点调整、三段分页读取，以及一次超长工具参数失败后的缩短重试，不能称为所有冗余均已消失。

每次请求的结构化进度在模型调用前发生，由替身回归核对身份/顺序；真实矩阵记录模型及预览时间，没有记录接收端逐事件时间，因此不能给出真实Assistant进度延迟或播报延迟数字。实际播报受正式FIFO和10秒合并政策约束，不应把请求开始时间当成实际播毕时间。两个SQLite只读重开integrity_check=ok；任务/目录隔离、续作run切换、局部修改其他文件字节保留、原生工具完整配对与WebKit按钮0→1检查通过。

### 原生模拟器

宿主缺少Simulator.app，但独立XCTest runner成功在iOS27模拟器实际启动并点击生产App。`scripts/test-writer-records-simulator.sh`使用独立设备82F45964-B809-469A-8358-9AEA6A2636F3，只读backup模型实验SQLite（包含WAL提交）至该模拟器，并复制对应作品文件；没有替换真机或原有用户模拟器数据。模拟器截图中的task_6是该独立评估数据库的JS修复用例，不是真机基线中的流程图task_6。

首轮页面点击均正常，分享断言因iOS27将Copy呈现为Cell而非Button失败；改为验证原生活动集合。种子改为一致backup后复测通过。最终扩展验收包含独立入口、图标/目标/状态/轮次、头部操作、文件列表与HTML WebView、PDF/ZIP原生分享、原生请求详情、任务对话分享；结果见最终检查表。该验证导入人工设定的测试目标及对应真实模型请求历史，不是在模拟器现场发起创作，不代表语音→真实模型→iOS窗口全流程。最终XCTest为1项通过、0失败，37.13秒；xcresult位于`/tmp/mobileharness-writer-ui.5us2Yf/WriterUI.xcresult`。

保留截图：[独立入口](Writer-Continuous-settings-separate-records.png)、[任务列表](Writer-Continuous-writer-task-list.png)、[头部/轮次](Writer-Continuous-writer-task-header.png)、[原生工具请求](Writer-Continuous-writer-native-request.png)、[HTML预览](Writer-Continuous-writer-file-preview.png)、[PDF分享](Writer-Continuous-writer-pdf-share.png)、[ZIP分享](Writer-Continuous-writer-zip-share.png)、[对话分享](Writer-Continuous-writer-export.png)。截图已经人工查看，头部状态成功/8轮，与一致快照中的实际请求总数匹配。


### 构建、安装与限制

检查证据分批保留：`/tmp/writer-continuous-check.log`为首轮两项失败；修复后`/tmp/writer-continuous-check2.log`完整exit0。增加进度并发eventID围栏后，定向回归`/tmp/writer-continuous-followup.log`通过：36项Writer消息参数组合（含2项真实10秒节流）以及空身份/最小化预览用例。后续完整检查`/tmp/writer-continuous-check-final.log`的Writer全部通过，但两项既有NativeState seeding测试在3秒调度期限内未得到通知、报invalidSnapshot；check2中同两项通过。隔离复跑`/tmp/writer-native-state-recheck.log`的5项NativeState用例全部通过：两项seeding各约9ms、整个组2.185s，未修改或放宽两项产品/测试契约。最终无并行Xcode构建的/tmp/writer-continuous-check-idle.log完整exit0，包含1011项主体测试和225项原生运行时测试，所有检查阶段、格式、资源边界及plist校验通过。未掩盖前述失败或放宽断言。

四目标iOS构建`/tmp/writer-continuous-ios-final2.log`exit0；最终列表时间补充小时/分钟后的四目标构建同样exit0，见`/tmp/writer-continuous-ios-delivery.log`。签名真机构建`/tmp/writer-continuous-device-final.log`成功，30项Skill资源、Live Activity及codesign深度验证通过。安装成功（序号5868），日志`/tmp/writer-continuous-device-install-final.log`；保持原应用数据，未清空SQLite。前两次启动被FBSOpenApplicationError7 Locked拒绝；用户解锁后再次启动成功，进程19462及Live Activity扩展在设备进程列表可见。已请求用户说原始简短目标进行语音/Writer体验，启动成功不等同交互通过。



本次交付未提交commit，没有增加模型输出上限、生产总轮数或整任务超时。真机语音及Writer窗口体验等待实际交互验收；真实Assistant播报延迟尚无数值证据。机器结果包含最终源码哈希、构建/检查/安装日志摘要及截图哈希，凭据检查未发现.env.local密钥值。

解锁启动后的只读base快照integrity_check=ok，原真机task_6 completed及task_5 failed记录仍在，证明安装未清空历史。WAL复制仍返回CoreDevice7000/POSIX60，不能从base推断本次是否产生新执行或最新进度。调查后删除临时SQLite副本，设备文件保持原样；真实新任务仍等待用户测试反馈。

## 2026-11-05 连续 HTML 预览与视口回归

本次处理流式生成/编辑触发原生页面重建、黑闪和滚动/缩放丢失。实际路径改为项目稳定文件根 + 稳定宿主 HTML + 两个轮换资源版本；流式检查点仅做宿主隔离 DOM 更新，完整运行仍导航执行脚本。未调用真实模型，未修改或清空真机 SQLite。

定向原生 macOS WebKit 测试已通过：同一 document/WKWebView/带 id 节点持续存在；上方插入250px内容后阅读锚点误差小于3px；pageZoom=1.25保持；相对 CSS 换版，脚本和事件属性不在预览执行；缺失 CSS 保留最后有效画面，模拟 wheel 事件时宿主不主动 scrollTo。Artifacts 实际存储/窗口/页面串联覆盖嵌套入口、连续五版、旧槽回收、资源加载和完整运行后的 reload，两资源槽各仅一版本。窗口动画回执由测试提供。

调查中真实测试发现并修正两类问题：测试窗口最初挂载的是配置安全根前的旧原生 view，导致 elementFromPoint 无可见尺寸（修正测试挂载）；删除初始 document URL 所属槽导致后续本地 CSS 加载失败（生产改用稳定宿主）。iOS 模拟器流式阶段确认六次更新保留原生1.5倍缩放、offset2400，并可继续滚动到2700。完整导航早期运行出现缩放回落到1.0/offset1800；修正为等待新内容帧同步，并避免重复赋值 pageZoom。随后覆盖完整运行与再次编辑，均保持1.5/2700；失败运行不计为通过。

iOS 27 / iPhone 18 Pro 模拟器使用生产 WebPageContainer/WebPageView 的独立宿主，最后两次执行通过（第二次另覆盖完整运行后再次编辑）。原生页面与带 id 节点未替换；预览禁脚本，完整运行执行脚本；远程 HTTPS、截图及现有 PDF 回归同轮通过。日志 /tmp/web-preview-simulator-frame.log、/tmp/web-preview-simulator-transition.log；结果位于脚本打印的模拟器 Documents/acceptance.json。完整脚本及构建结果见下列补充。真机连续拖动/双指缩放和肉眼闪烁尚未验收；程序化 WebView 测试仅证明视口与文档连续性，不能证明所有设备每一帧均无闪烁。

| iOS程序化阶段 | 原生缩放 | 纵向 offset |
| --- | ---: | ---: |
| 初始阅读 | 1.5 | 2400 |
| 连续预览 2–5 | 每次1.5 | 每次2400 |
| 继续向下滚动并更新第6版 | 1.5 | 2700 |
| 第7版完整脚本运行，等待原生布局稳定后 | 1.5 | 2700 |
| 第8版再次编辑／切回安全预览 | 1.5 | 2700 |

SDK 机制参考：[WKWebView](https://developer.apple.com/documentation/webkit/wkwebview)、[allowsContentJavaScript](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript)。使用公开 WebKit/UIKit API，不注入页面特权通信桥或引入第三方 DOM 库。

最终自动化记录：

- /tmp/web-preview-check.log：scripts/check.sh exit0，边界/格式/资源/plist检查通过；主体Integration 1024项、LiveRuntime226项通过。审阅发现 NativePresentationTests 在既有 cameraNativeMetalDrawStopAndLayerHandoff 启动后没有完整终态输出，不能把脚本exit0解释为该原生UI套件全部执行通过；本次未修改该Metal用例或检查脚本。
- 因此另跑 swift test --skip-build --filter 'web[A-Z]|artifactPreviewRotates'，/tmp/web-preview-webkit-final.log exit0：5项UI Web/URL、2项集成、4项工作区/共享窗口回归均通过，其中新增取消后保留页面断言通过。
- scripts/build-ios.sh exit0，四个 scheme（MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero）全部 BUILD SUCCEEDED，30项Skill资源及原生Live Activity验证通过；证据 /tmp/web-preview-ios.log。未安装真机或调用真实模型；不将独立模拟器宿主或编译结果描述为真机手势验收。
