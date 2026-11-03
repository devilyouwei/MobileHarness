# Web Skill 上下文 missing 修复验证

日期：2026-11-03；分支codex/webkit-actions。用户真机截图显示agent.context.snapshot / missing，发生在请求打开B站并加载Skill之后。

## 根因与回归

WebBrowsing/WebDrawing声明ui.web，但AssistantStateBindings漏注册；上下文采集在浏览Action前失败。旧状态覆盖测试只枚举六个旧Skill，新增的两个Web Skill未参与检查。现改为读取打包Catalog动态枚举，并执行每项Skill的加载、状态采集、释放和再次采集。

修复前定向测试退出1：状态集合差异明确为ui.web，采集测试抛出missing（`/tmp/web-skill-repro.log`）。补注册后曾发现测试装配使用了macOS上没有iOS业务子节点的Actions根，测试仍抛missing；改为明确的Actions/Agent被动事实替身，UI/Platform保持真实读取，没有放宽生产错误处理。

最终3项定向测试退出0（`/tmp/web-skill-focused.log`）：全部打包Skill状态覆盖与完整加载/释放链路通过；真实macOS WebKit本地HTML/CSS/JS、截图及本地文件URL不披露/关闭状态通过。ui.web只投影content和远程url，Runtime不进入助手上下文。

## 完整检查与安装

`./scripts/check.sh`退出0（`/tmp/web-skill-check.log`）：981项Integration、146项AppWorkflow及独立225项长时测试通过，长时阶段204.113秒；模块边界、格式、Python测试与工程配置校验通过。`./scripts/build-ios.sh`退出0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero四项构建通过（`/tmp/web-skill-ios.log`）；git diff --check通过。

真机Debug签名构建2026110305通过（`/tmp/web-skill-device-build.log`）；codesign严格深层校验、29项Agent/Skill资源及Live Activity校验通过。已原位安装至Youwei’s iPhone 17 Pro（sequence5692），独立应用清单确认dev.mobileharness.app版本0.1.0 / build2026110305，系统启动成功。没有卸载或清空数据；签名配置未修改。证据：`/tmp/web-skill-device-install.json`、`/tmp/web-skill-device-after.json`、`/tmp/web-skill-device-launch.json`。

这些测试复现并验证上下文接入缺陷；未调用真实模型访问B站，不能据此宣称B站页面全部交互或模型内容分析已验收。
