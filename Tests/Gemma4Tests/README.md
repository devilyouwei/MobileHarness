# Gemma 4 tests

✅ 已实现：权重无关的窗口回归使用注入计数器验证真实生产裁剪算法，覆盖20轮→最新5条消息、system完全移除／Unicode当前输入原样保留、中文／emoji、模板开销、输出预留／显式预算、当前输入过长、取消及原请求不变；真实tokenizer／本地生成另行验收。

Purpose: verify local ChatCapability contracts. Design goals: weight-free regressions plus explicit real-model opt-in.

Prompt rendering preserves system/user/model turns; reasoning filtering withholds partial markers and thought text; invalid requests fail before loading.

## Consecutive user message boundaries

The exact prompt regression preserves every consecutive-user turn. Existing alternating-role assertions remain; no real Gemma weights or inference are required.

## 待实现

- Real inference, cancellation and unload/reload require HARNESS_TEST_GEMMA4=1 and HARNESS_GEMMA4_ROOT pointing at the paired CoreAI b2 decoder/QAT table tree. No test weights are committed.

✅ 回归验证首部、中间、末尾及超长system均不进入tokenize，保留用户消息边界、原请求及本地输入限制。

✅ 回归覆盖失败历史中的空assistant／空白消息、末尾system移除、空当前输入不可回退旧user、无当前user及具体错误原因。

✅ 回归覆盖iOS 1024／macOS 4096及模型更小窗口解析、1024内长system与历史裁剪、输出预算和当前输入超限拒绝。
