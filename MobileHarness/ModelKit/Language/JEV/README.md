# Decision 候选选择

## 职责和边界

DecisionCapability、DecisionRequest、DecisionResult 属于基础 ModelKit 契约。请求携带当前文本、候选项、问题和 InferenceContext；结果为合法候选及可选分数，或明确 abstained。候选唯一且非空，至多255项，文本至多20 KiB；分数有限且在0–1内，不表示校准置信度。路由、打断和业务工具由调用方拥有。

## D3 执行

ModelKitD3 独立编译 D3Decision，依赖 ModelKitCoreAI 和现有 Tokenizers。默认装配以 d3-edge 注册到 language.decision，制品目录 D3Edge。加载 manifest/decision_config/tokenizer/decision.aimodel 后验证 text、512、255项读出契约。固定 chat template 关闭 thinking，短输入左填充，position_ids 为四组同序位置；超长输入明确失败，不截断。GraphModel 使用系统默认 specialization，与发布制品验证路径一致。

一个资源租约执行一次 stateless 图并输出一个 DecisionResult；按当前候选数量裁取 logits 后 softmax。InferenceTaskControl 取消并加入原生执行，再释放租约。下载、加载和卸载由 ModelKit 资源体系拥有；调用者不得以超时冒充资源释放。

真实权重和测试证据见 [全双工验证](../../../../docs/validation/Assistant-Full-Duplex.md)。[Language](../README.md) · [CoreAI](../../Support/Backends/CoreAI/README.md)
