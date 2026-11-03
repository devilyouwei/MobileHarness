# WebKit 与绘图 Action 验证

日期：2026-11-03。分支：`codex/webkit-actions`。对应[需求与实施计划](../completed/WebKit-Actions-Plan.md)。

## 验证范围

- Swift 行为测试：受限路径、读取后唯一局部替换、歧义/容量失败不污染草稿、磁盘不可变版本、CAS冲突、重开/删除与清理失败重试。
- 独立编辑循环：脚本化模型替身验证连续请求、独立request/scope、错误反馈、render后finish、取消、截图进入下一轮且旧图清除；Action创建→保存→同项目局部更新使用真实工作区与明确的页面替身。
- Assistant：五类网页截图结果进入既有受source/session/input约束图像观察链路；Skill与静态/运行时目录共同验证。
- 真实macOS WebKit：独立HTML/CSS/JS读取、JS执行、实际可见窗口JPEG截图、未挂载和失活拒绝。
- 真实iOS 27模拟器（iPhone 18 Pro）：生产WebPageContainer/WebPageView编入独立测试宿主，依次读取两版中文HTML/CSS/JS，检查JS更新和计时变化，真实截图，访问远程HTTPS页面，随后重新打开本地版本。

## 模拟器证据

`scripts/test-webkit-simulator.sh` 成功；最终结构化结果为 `passed`。本地第二版JPEG为96,573字节，1024像素宽。入口HTML、外部CSS、外部JS和计时器均实际执行；远程页面观察和JPEG实际取得。图片为手写验收fixture，不能据此宣称真实LLM能生成同样图形。

- [结构化证据](../../output/webkit-acceptance-2026-11-03.json)
- [本地第二版截图](../../output/webkit-acceptance-2026-11-03.jpg)

复现：先启动一个iOS 27模拟器，再运行 `./scripts/test-webkit-simulator.sh`。脚本不更改主App模型/密钥设置，最多等待55秒；失败返回非零，证据保存在隔离测试App的Documents目录。

## 修复过程中保留的失败

1. 直接使用Command Line Tools执行swift test找不到metal；改用仓库脚本选择的完整Xcode工具链。
2. 首次WebKit诊断脚本换行未转义，导致JS解析失败；已修正并由原生测试通过。
3. 磁盘fileURL调用选中了协议默认异步拒绝实现；DiskFileStore显式实现异步原生文件入口，真实版本读取/重开测试通过。
4. 模拟器无charset的中文页面乱码；fixture补charset，生产HTML发布补UTF-8 BOM，后续中文观察正确。
5. 远程页面正文不含标题文字，初始验收断言错误；改为分别验证实际标题和非空正文。
6. 截图宽度初始按点计算，3x屏幕输出3072像素；已按screen scale换算为1024像素。
7. 全仓首轮发现Web静态声明遗漏、UI子能力数量断言和新增Skill后的提示预算；已补登记并同步回归边界。并行构建时一个原有PlatformState测试超过3秒期限，最终结果另记。

## 完整检查状态

最终源码 `./scripts/check.sh` 退出码0：模块边界、格式、Python回归、Swift测试和工程/隐私/权限配置校验通过。其中IntegrationTests为980项（65.327秒），AppWorkflow为146项；独立原生/长时阶段225项（204.493秒）通过。原有PlatformState超时未在隔离完整重跑中复现。完整日志：`/tmp/mobileharness-web-check-final2.log`。

最终源码 `./scripts/build-ios.sh` 退出码0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个scheme均为BUILD SUCCEEDED。打包Skill资源与Live Activity检查通过。日志：`/tmp/mobileharness-web-ios-final2.log`。`git diff --check`通过；本次新增及调整的文档链接存在。

## 验收限制

本轮未调用真实LLM：测试环境未提供OPENAI_API_KEY/模型环境配置，编辑循环采用明确替身，未新建或更换用户凭据。生产装配复用Assistant的ModelKit.language；真实模型生成质量、不同provider的JSON可靠性及长任务成本需使用实际配置验收。没有物理iPhone验收，也没有将静态图像当作完整动画时序/性能验收。项目明确限制8项目、每项目16版本、单次24轮模型请求，容量超限会失败，不能声称无限开发或任意浏览器功能。

## 2026-11-03 用户请求安装真机

复用现有本地签名，以命令行构建号2026110304完成MobileHarness / Debug iPhoneOS构建；严格深层签名校验、29项Agent/Skill资源及Live Activity资源校验通过。原位安装到Youwei’s iPhone 17 Pro成功（bundle dev.mobileharness.app，databaseSequenceNumber 5684），未卸载或清空数据。独立应用清单确认版本0.1.0 / build2026110304，系统启动请求成功。

证据：`/tmp/webkit-device-build.log`、`/tmp/webkit-device-install.json`、`/tmp/webkit-device-after.json`、`/tmp/webkit-device-launch.json`。本次只确认真机构建、安装与系统启动；WebKit真机交互、真实模型生成质量及性能仍未验收，不改写上轮验收限制。签名设置和源码版本设置未修改。

后续真机暴露Web Skill状态来源漏注册，导致loadSkills后上下文missing。缺陷、旧测试覆盖不足、修复回归与2026110305安装证据见[专项修复记录](Web-Skill-State-Fix.md)；原测试通过不代表该漏测链路当时正确。
