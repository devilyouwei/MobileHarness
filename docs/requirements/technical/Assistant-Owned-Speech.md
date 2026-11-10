# Assistant 内聚语音合成与后续输入协调

日期：2026-11-10。用户授权本轮完成设计整理与合成迁移；分支 `codex/assistant-owned-speech`。

## 范围

本轮将 SpeechSynthesis 独立 Agent 收敛为 Assistant 私有的异步语音生产能力。保留现有分段、半双工聆听、实际播放和 Action 调度行为；不实施多源批次、小模型判断、全双工音频或数据库统一迁移，不新增目录、模块或依赖。

后续输入协调归 Assistant：统一有界收件箱分别管理正式输入、最新状态、控制与配对反馈；规则先处理明确事件，JudgeCapability 为剩余语义提供候选分类或 abstained。冻结成员身份/版本后请求模型，新消息继续接纳；控制不等待普通 FIFO。被选中、请求完成、动作完成与播放完成分别结算。语音结束检测属于 SpeechPerception 的感知事实，不能替代 Assistant 是否启动认知的判断。详见 [多源输入计划](../Assistant-MultiSource-Input-Coordination.md)。上述能力本轮不实现。

## 实施设计

1. `Agents/Assistant` 新增内部语音生产器，拥有一个串行 TTS worker、有界队列、在途接纳、音频句柄及播放展示。并行含义为合成与播放/其他 Action 并行，语音生产保留 FIFO；预留句柄成功即返回，不等待全部 PCM。ModelKit 执行 TTS，StorageCache 管理音频，Actions 拥有真实播放/停止/排空。
2. `Agents/Support/Chat` 定义消费者拥有的窄语音接口并注入 Worker。文本分段后直接请求音频句柄，再发出原播放 Action；失败加入句柄取消，保留原始及清理错误。停止/取消关闭相应输入的生产；共享 Worker 不构造 Assistant 私有实现。
3. AssistantExecutionSession/AgentRuntime 构造并拥有稳定语音生产器，语音原生会话安装 ModelKit 与 AudioCache 能力；停机先关闭接纳并加入在途接纳与生产再释放 scope。原生 VoiceAgentSession 只连接感知注册和 Assistant 语音能力，不再创建/注册合成角色。实际播放事实回到 Assistant 自有展示；展示通过 Assistant 身份的内部工具，不产生认知输入。
4. 删除 `Agents/SpeechSynthesis`、Resources 中对应角色及 Catalog 声明、`speech.synthesize`/`speech.cancel` 通信协议、根容器及反射路径；把仅用于合成的请求校验移到新拥有者。同步构建文件、资源检查和依赖边界检查，不保留旧/新双实现。
   `SpeechPlaybackFailure.swift` 同步从 SpeechPerception 移入 Assistant，保持 App 注入的错误适配接口和原始错误，避免感知目录继续拥有合成/播放错误文案。
5. 更新 Assistant、Agents 根、Support/Chat、Communication、SpeechPerception、Actions/Speech、App/Composition、Resources 以及总体技术设计；其内容只描述最终实现。历史文档保留当时事实，通过迁移说明区分已删除路径。

## 运行与失败契约

- 生产器的活句柄及尚未注册的接纳合计至多 32；一个 active producer；共享 AudioCache 仍最多 32 个活句柄，每段至多 8 MiB。满载显式拒绝。播放按原 Gateway Channel 顺序读取流，不把接纳当完成。
- 固定生产者身份为 Assistant，音频归属 session/input；不能从任意消息指定另一个角色。句柄注册后再次检查生命周期及取消，禁止迟到接纳复活旧会话。
- 生产器保留至多 32 个活句柄关联，缓存释放/失败回调立即退休关联；输入清理按 session/input 二元身份选择，不能仅凭 inputID 清理另一个会话。缓存已关闭或先行退休时，接纳重验显式失败。
- 生命周期独立于 UI 页；语音 scope 拆卸和根停止加入所有接纳/生产，取消按原输入关联进行。失败关闭缓存并唤醒读者；取消等待 provider 真正结束，避免生产者通过缓存回调等待自己。
- 合成完成不代表播放完成。旧 audioID 的结束不能撤下新播放活动。播放提交失败、推理失败、音频格式/序号错误和缓存溢出保留实际失败，不能触发重复业务 Action。

## 验证计划

迁移已有真实 Gateway/缓存/播放集成测试与 Agent 文本探针；增加或调整 FIFO 与播放并行、来源/输入隔离、队满、取消中的接纳、生产停机加入、原始失败传播及 Assistant 展示身份测试。删除旧角色通信专属测试并以窄接口和 scope 所有权测试替代。

运行定向测试、`./scripts/check.sh`、完整 Xcode 可用时的 `./scripts/build-ios.sh`，证据记录在 `docs/validation/Assistant-Owned-Speech.md`。自动化替身/模拟器编译不替代真实 TTS、麦克风与真机播放/打断验收。

## 状态

设计整理和合成迁移已完成，完整自动检查与四个 iOS 模拟器目标构建通过，详见[验证记录](../../validation/Assistant-Owned-Speech.md)。真实模型与 iPhone 播放/打断验收未执行；后续输入协调、模型接入与全双工仍独立待实施。
