# 提示词所有权验证

日期：2026-11-08。范围见[需求与实施方案](../requirements/technical/Prompt-Ownership-Plan.md)。

## 实施结果

各角色 Agent.json 升为 v8 并维护公开 description；Support 投影为不变的 AgentCore v7 函数/通信配置。Assistant 只维护自身身份，BasicSkill/TaskActions 维护通用 Task 教学，Writer 私有控制及内容格式指令迁入自身资源。实际请求通过当前实例权限与同一执行适配生成公开目录；只有受支持且获授权的 Writer 可被委派。

## 自动验证

- 定向回归：7 项测试通过，含 9 种无效元数据、8 种文件路径/格式、权限收窄、私有指令隔离、Writer 自描述、Task 平级教学与不可加载 writing。日志：`/tmp/mobileharness-prompt-focused.log`。
- 首次全量检查揭示两处测试仍引用旧 delegation 模板/旧章节名，已改为自描述与 DELEGATABLE AGENTS 契约；该次普通 IntegrationTests 为 1090 项、仅此 2 处失败；原生 LiveRuntimeTests 的 227 项全部通过（207.801 秒）。修正后 `./scripts/check.sh` 完整复验退出 0：架构/资源边界、6 项 Python 测试、Swift 严格格式、各包自动测试和 plist 校验全部通过；普通 IntegrationTests 的 1090 项全部通过（65.398 秒），原生 LiveRuntimeTests 的 227 项全部通过（206.402 秒）。日志：`/tmp/mobileharness-prompt-check-final.log`。
- `./scripts/build-ios.sh`：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四目标全部构建成功。最终 App 的 30 项资源逐字节校验通过，包含 Writer 新增 Instructions.md 和 Prompts.json；Core 协议与 Island 资源校验通过。日志：`/tmp/mobileharness-prompt-ios.log`。

- 文档新增引用路径及相对链接检查通过；`git diff --check` 通过。

## 验收边界

自动化使用合成输入和模型替身，证明装配、授权、格式及执行回归，不证明真实模型一定按提示词选择动作。尚未运行真实模型重测截图中的卡通化绘图、查找打开作品及并存前台目标，也未做物理手机验收或安装。本次不修改历史验证中的失败记录。
