# Agents 开发规范

适用于本目录及其子目录。先读[仓库规则](../../AGENTS.md)、[模块设计](README.md)和受影响角色的 README。

## 职责归属

| 位置 | 开发职责 |
| --- | --- |
| 模块根 | 角色注册、生命周期、总装配接口和跨角色契约。 |
| [Assistant](Assistant/README.md)、[Writer](Writer/README.md)、[Memory](Memory/README.md) | 对话与决策、委托作品工作流、历史和记忆请求，由各角色独立拥有。 |
| [ApplicationControl](ApplicationControl/README.md)、[VisionPerception](VisionPerception/README.md)、[SpeechPerception](SpeechPerception/README.md) | 应用设备与设置请求、相机与视觉跟踪、聆听与语音感知。 |
| [Support](Support/README.md) | 通用认知与通信机制、授权适配、上下文和 Chat。 |
| [Resources](Resources/README.md) | Agent、Skill、目录、提示词及本地化声明。 |

## 开发边界

- 把角色的输入、业务工作流和输出放在相应角色目录。跨角色能力通过公开契约和认证消息交互，禁止直接访问同伴的私有状态。AgentCore 只依赖中立 FunctionContracts，禁止向共享机制放入角色特判。
- 角色通过被授权的执行接口发起业务动作。禁止导入 Actions、CallRuntime 或 ExecutionRuntime，也不要从角色绕过注册执行链路去调用原生副作用。消费注入的只读原生事实和模型能力。
- 领域 Signal 的类型、负载和业务授权由对应端点所有者定义。由 Agents 组装角色通信负载，Gateway 负责注册后的传输。接收角色决定接纳、推进和完成。
- 冻结每轮可见权限和 Skill 快照。把工具回执与原调用、会话和轮次关联。只有具有执行反馈语义的结果能推进认知。角色通过其授权接口选择 ActionCall 或 ToolCall。需要串行的 Tool 工作流自行等待前一项完成。灵动岛走固定内部 Tool 权限，禁止在 Skill 注册或教学。
- `useStates` 选择精确的公开状态源。只读采样已发布事实，禁止读取同伴私有 Context 或因读状态创建资源。长期感知、输出和后台任务由角色或会话持有，随角色生命周期取消并加入。

## Skill 编写与评审

1. 先检查现有 Skill 及依赖。用 [Skill 资源契约](Resources/SkillAuthoring.md)核对 ID、revision、目录映射、canonical path、alias、Channel 和事实来源。按流程授权并同步各语言资源。
2. 在 Instructions.md 写可复用流程。说明用途、所需权限和事实、调用顺序、等待点、用户交互、取消、失败及清理。未知事实通过已声明来源或能力确认。业务状态、用户原文和实际媒体身份来自运行时。共享协议、角色身份与 Task 控制由其所有者维护。
3. 示例按条件、当前输出、真实反馈后的后续步骤组织。XML 示例把实际模型输出放在独立代码块。使用已注册别名和有效参数，虚构 ID 或反馈只用于标明的示例。重复调用以真实效果为准，尤其是已提交副作用的操作。
4. 核对依赖环、容量、组合冲突、非法或重复绑定、加载失败的原子性和后续轮次的目录可见性。历史使用当轮修订号及目录证据。用 [Agents 测试](../../Tests/Agents/README.md)验证请求快照、回执关联、等待用户和结束流程。配置行为变更还要核对最终随包资源。

例如，[相机与视觉配置](Resources/Skills/Photography/Skill.json)绑定 `Camera.Capture.takePhoto`，由实际回执提供预览身份。业务教学维护在[摄影指令](Resources/Skills/Photography/Instructions.md)及简体中文对应资源。

公开简介分别写在 Description.md 与 Description.zh-Hans.md，使用方法写在对应语言的 Instructions.md。以下配置仅演示就绪相机的拍照绑定。完整流程按实际目标组合打开、拍摄、保存和关闭能力。

```json
{
  "version": 4,
  "id": "capture-only",
  "revision": 1,
  "dependencies": [],
  "useActions": [
    {
      "path": "Camera.Capture.takePhoto",
      "callType": "action",
      "alias": "takePhoto",
      "channel": "Camera"
    }
  ],
  "useStates": ["actions.camera"],
  "useInstructions": ["Instructions.md"]
}
```

指令先确认就绪，调用 takePhoto 后等待实际结果。收到成功回执后才报告照片已拍摄。
