# Skill 驱动 State 观察验证

日期2026-11-03；分支codex/webkit-actions。移除Assistant路径/字段选择表，生产装配安装单一App-backed resolver，Skill.useStates决定观察范围。保留生产者完整Business，排除Runtime/health/children/metadata。单项读取/解码/路径缺失返回unknown/null与固定path/code诊断，异常原文不进入观察。取消、closed、代际失效、8KiB单项/16KiB总量及raw256KiB限制保持。

显式source接口保留给独立宿主与测试，生产不再逐路径注册。完整Business使ui.windows等数组不再被Assistant过滤为unknown。新增任意路径及混合失败回归；全部打包Skill测试要求不存在stateUnavailable诊断，开发期仍可发现拼写/接线问题。

`./scripts/check.sh`退出0（`/tmp/skill-state-check.log`）：982项集成及225项独立长时测试通过，长时阶段205.274秒；其余测试、边界、格式和工程配置检查通过。追加回归后定向12项测试通过（`/tmp/skill-state-focused.log`），含新路径/嵌套对象、混合失败、全部Skill无缺失诊断及取消/关闭/容量验证。`./scripts/build-ios.sh`退出0（`/tmp/skill-state-ios.log`），MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero四项构建通过，包内资源校验通过。`git diff --check`通过；本轮未重新安装真机。未进行真实模型或真机交互验收，不将协议/构建检查视为行为遵循或性能验收。

## 2026-11-03 用户请求安装真机

当前分支Debug iPhoneOS签名构建2026110306通过（/tmp/state-device-build.log），codesign严格深层校验、29项Agent/Skill资源及Live Activity校验通过。原位安装至Youwei’s iPhone 17 Pro成功，sequence5700；独立清单确认dev.mobileharness.app版本0.1.0 / 2026110306，系统启动成功。保留应用数据与配置，未卸载，未修改本地签名设置。证据：/tmp/state-device-install.json、/tmp/state-device-after.json、/tmp/state-device-launch.json。安装包包含统一State观察及Web Skill revision2；安装/启动不代表真实模型或网页交互验收完成。
