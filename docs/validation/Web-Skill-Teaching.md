# Web Skill 教学优化验证

2026-11-03，codex/webkit-actions。范围：web-browsing/web-drawing的Instructions.md、revision2与发现描述；Action绑定、依赖、State来源和执行实现保持原契约。

参照Photography、HistoryQuery、ApplicationControl与BasicSkill，明确单次操作不强制建Task、依赖结果分轮、browse/develop已包含窗口呈现与截图、项目身份复用、观察范围、失败不重放，以及作品展示与关闭/删除的区别。示例直接来自打包指令，通过生产GenerationTrace解析器检查。

## 验证记录

定向测试退出0（`/tmp/web-skill-teaching-focused.log`）：4项测试，其中Web示例覆盖2个参数用例；协议解析、Skill目录和全部Skill状态加载/释放通过。实测完整提示UTF-8大小：基础25,243字节，Photography36,883字节，WebBrowsing31,131字节，WebDrawing（含浏览依赖）36,910字节。Web回归预算据此设为38,000字节，不放宽模型请求上限。

完整`./scripts/check.sh`退出0（`/tmp/web-skill-teaching-check.log`）：982项集成测试、独立225项长时测试（205.720秒）及其余测试、边界、格式、工程配置校验通过。`./scripts/build-ios.sh`退出0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero四项均BUILD SUCCEEDED（`/tmp/web-skill-teaching-ios.log`）。29项打包资源逐字节校验通过；最终包内WebBrowsing/WebDrawing均为revision2，指令分别4,335/5,010字节。`git diff --check`通过。定向测试初始等待另一项SwiftPM检查释放共享构建目录，未中断其他任务或修改其窗口/相机代码。

未请求真实LLM，未执行B站实际内容交互或绘图质量验收；示例解析和提示预算不等同模型遵循度。本轮未重新安装真机，资源需随App更新生效。
