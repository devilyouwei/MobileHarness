# BasicSkill 控制教学验证

2026-11-08，对应[实施计划](../requirements/technical/BasicSkill-Control-Teaching.md)。BasicSkill revision 50，schema 仍为 3。

## 实现与静态契约

Instructions 重组为六部分：概念、上下文、决策、各控制 Action 的效果、生命周期、输出/反馈/失败。明确 Skill 包含指令、函数、State 选择与依赖，Task 保持持续目标；加载不是业务执行，能力释放不等于任务结束或撤销效果。九项注册控制均有效果说明，Task 替换的多阶段失败不承诺恢复旧任务。BasicSkill 无业务 Skill ID 或业务场景示例。

JSON 与改动前逐字段比较，只有 revision 和 description 改变；version/id/dependencies/useActions/useStates/useInstructions 均相同。没有生产 Swift、权限、模块接口或跨模块运行流程变更。参数和通用调度协议仍由 canonical Action/Core 拥有。

新增资源回归动态比对效果段落与注册别名，避免漏教动作；扩展全非基础 Skill 测试，验证加载后的 State 选择以及释放后函数/教学/State 恢复。沿用真实 Task 状态转移回归检查显式释放任务能力、非法释放原子拒绝、接管和终态回收。

## 自动化与构建

- 首轮定向运行暴露旧原句断言（Skill ID 不是标签），全仓运行另暴露 Speech/Display 映射原句断言。保留这些正确约束并恢复清晰原句，没有放宽测试。初始日志 `/tmp/basic-skill50-focused.log`、`/tmp/basic-skill50-check.log`；旧文本全仓运行在确认问题后终止，仅停止本任务进程。
- 首轮 iOS 构建后的资源校验发现编辑过程中的旧 Instructions，正确报 Stale Agent asset；不计为成功验收。日志 `/tmp/basic-skill50-ios.log`。
- 修正后 33 项定向测试通过：`/tmp/basic-skill50-focused-retry.log`。
- `./scripts/check.sh` 完整退出 0，包含边界、Python、格式、工程配置、1102 项 IntegrationTests、227 项原生/运行时测试及其余测试目标。日志 `/tmp/basic-skill50-check-final.log`。这不等于物理设备验收。
- 最后补充两句通用教学（按字段含义读事实、JSON 嵌入 XML 的引号）和通用任务完成场景后，36 项定向测试再次全部通过，含资源、上下文、Skill 生命周期、能力边界与场景声明校验。日志 `/tmp/basic-skill50-verified.log`。本次新增场景也通过该轮校验，不把此前全仓运行当作新增场景已执行的证据。
- 最终 `./scripts/build-ios.sh` 四个目标全部 BUILD SUCCEEDED，Agent/Island 资源校验通过，退出 0。日志 `/tmp/basic-skill50-ios-verified.log`；此轮打包使用上述最终文本。
- 最终基础/Photography/WebBrowsing 提示分别为 22,818 / 36,711 / 30,061 UTF-8 字节，在原有预算内；没有放宽预算。`git diff --check` 和改动测试文件格式检查通过。

## 真实模型与合成执行

Qwen3.8 Max，生产 Assistant/Gateway、已编译 IntegrationTests 与合成设备/网页反馈。每轮先逐字节核对编译资源包的 BasicSkill 与源码一致，再使用既有 evaluate-qwen.py 的 skip-build 路径；测试二进制位置已知，省略会占共享构建锁的路径查询，不修改共享 bundle。两轮 sourceUnchanged 均为 true；原始回复、调用、请求/相关源码 hash 摘录见[测量记录](../measurements/basic-skill-control-2026-11-08.json)。

首轮自动评分 5/9。除技能数组 XML 引号错误、误读相机已启用状态、点头误选表情外，旧 task-continue 场景还遭遇评估夹具不适配：模型调用当前 canonical 的 previewID，QwenEffects 仍使用 mediaID 比对，导致 photoUnavailable。该失败保留，不能据此判断 Task 完成教学失效；没有修改摄影实现或伪装成功。

最后一轮用不依赖摄影媒体的 `basic-task-confirm-completion` 替代该夹具场景：任务目标是等待用户选择，用户明确选择并确认结束后，模型执行 task.end 并进入实际终态。终轮 7/9：

| 场景 | 结果 |
| --- | --- |
| 相机冷启动 | 先独立加载 Skill，反馈后打开，通过 |
| 相机能力已加载 | 直接关闭且不重复加载，通过 |
| 单次拍摄 | 先 takePhoto，未就绪失败后 openCamera 再 takePhoto；两次调用，不符合用例要求，失败 |
| Task 无关旁支 | 保留原目标和能力，通过 |
| Task 用户取消 | 取消且进入终态，通过 |
| 点头请求 | 输出 express(happy)，未加载机器人 Skill，失败 |
| URL 冷启动访问 | 加载后访问，通过 |
| 普通知识问答 | 无需加载，直接回答，通过 |
| 用户确认选择任务完成 | task.end 后无活跃 Task，通过 |

两轮场景不完全相同，不能直接把总通过率差异当作提升幅度。剩余动作选择、就绪前提和失败后重试遵循不足仍需后续处理；没有在 BasicSkill 中添加业务特判。旧摄影评估夹具需要独立对齐当前预览契约。

## 未执行范围

上述教学验证结束时未安装手机、未访问真实网站、未运行真实机械臂或真实摄影设备。后续手机安装单独记录如下。原生/运行时测试、构建和合成执行均不能作为这些操作的真实验收；也没有宣称提示词能确定性保证所有模型行为。

## 真机安装（2026-11-08）

用户要求安装当前版本。目标为已连接的 iPhone 17 Pro，安装前为 0.1.0 / 2026110806。使用既有本地签名、MobileHarness 真机方案构建 2026110807，严格校验签名及 Agent/Skill、Live Activity 资源后覆盖安装并独立核对版本。此次不修改生产代码或本地签名配置；安装结果与真实模型行为验收分别记录。

安装结果：签名 Debug 真机构建成功，严格深层签名、30 项 Agent/Skill 资源及 Live Activity 打包校验通过。覆盖安装成功（安装序列 6360），独立应用清单确认 0.1.0 / 2026110807；包内 BasicSkill revision 50 与源文件一致。未执行卸载、主动清空应用数据或更改 Provider 配置。

系统启动请求失败：手机处于锁屏状态，返回 FBSOpenApplicationErrorDomain code 7（Locked）。安装已完成，但未验证启动、原生交互或真实模型行为；解锁后可手动打开应用。[测量记录](../measurements/basic-skill-control-2026-11-08.json)的 deviceInstallation 保存安装结果和本机原始日志哈希。
