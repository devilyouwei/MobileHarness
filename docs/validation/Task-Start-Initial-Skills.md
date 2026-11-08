# task.start 初始 Skill 教学修复（2026-11-08）

## 根因与修改

运行时能力未删除：TaskActions 仍声明可选 skills，BasicSkill 绑定 canonical 函数，AgentTaskSkillState 在 task.start 中原子加载初始 Skill 并创建前台任务。问题是 BasicSkill 的示例先不带 skills 启动，再要求下一轮 loadSkills；它与参数能力相矛盾并引导了多余调用。

修改仅涉及 BasicSkill 私有教学、Skill.json revision（45→46）、回归测试和说明文档，生产 Swift 和公共参数保持原实现。通用 Task/Skill 教学由 BasicSkill 拥有，Assistant 身份和 Writer 私有指令未改。

现在示例直接携带单项或多项 JSON 数组；任务所需的已有 Skill 也可在启动时转为任务持有。模型收到成功反馈后，下一轮即可使用提交后的函数和 Skill 指令。后续新增缺失能力、无 Task 的单次工作才单独 loadSkills。启动仍独占整个响应，不允许在同一轮提前调用尚未提交的函数。task.delegate 的平级入口及 Writer 归属保持不变。

## 确定性回归

专项命令筛选 bundledTask、taskOutputRules、skillTransitionsAreAtomic、taskOwnsRequestedSkills、assistantPhotographyUsesLocalTaskAcrossUserInputsAndReACT、writingSkillCannotBeLoaded、foregroundTaskRejectsBackground，8 项通过。

新增测试从实际打包 Instructions 提取 task.start 示例，经 XML 解析和默认 canonical 目录校验，直接提交真实 Task/Skill 状态，验证：

- 单 Skill 和多 Skill 都在一次 task.start 后可用；下一轮包含对应函数和 Skill 正文，没有额外 loadSkills。
- 无效 Skill 数组不能部分加载，也不能留下新任务。
- 先前目录快照不被污染；任务记录持有所需 Skill。

既有 Assistant/Gateway/SQLite 摄影回归确认跨模型请求的实际提交边界：启动携带 photography 后下一轮直接使用摄影能力。模型、相机效果为脚本/替身，不是实际模型选择正确率或真机拍摄验收。

## 仓库检查

[检查证据](../measurements/task-start-skills-2026-11-08-checks.json)保存命令、退出码、日志哈希及资源/测试指纹。

- `./scripts/check.sh` exit 0：1,095 项常规集成测试、227 项原生运行时测试通过；格式、模块边界、Python、资源和 plist 检查通过。
- `./scripts/build-ios.sh` exit 0：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四目标成功；App Skill 资源及 Live Activity 包装校验通过。
- 收尾时提示词、配置与新增测试内容和验证时指纹一致；文档路径与 diff 格式核对通过。

本轮没有付费模型实验或真机验收，自动测试不等同于真实模型的遵循率。原需求与实施范围见[归档](../completed/Task-Start-Initial-Skills.md)。

## 真机安装（2026-11-08）

用户要求安装最新版本。目标为已连接的 iPhone 17 Pro，安装前版本为 0.1.0 / 2026110805。使用既有本地签名构建 2026110806，校验签名及 Agent/Skill、Live Activity 资源后覆盖安装，核对版本与系统启动。保留应用数据，不更改 Provider 配置，不修改业务代码。安装/启动结果与 task.start 的真实模型遵循率、真机交互验收分别记录。

安装结果：签名 Debug 真机构建 0.1.0 / 2026110806 成功；严格签名、30 项 Agent/Skill 资源及 Live Activity 打包校验通过。覆盖安装成功（安装序列 6352），独立应用清单确认构建号 2026110806。正常启动成功，进程清单确认新安装路径下 MobileHarness PID 24957 运行。未卸载、清空数据或修改 Provider 配置。

[真机安装证据](../measurements/task-start-skills-2026-11-08-device.json)记录版本、签名/资源校验和本机原始日志哈希。本次确认真机安装与系统启动，未调用真实模型验证 task.start 携带 Skill 的选择行为，也不替代交互验收。
