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

## Native tools

GemmaToolProtocolTests covers neutral declarations to native syntax, nested argument values and Unicode, generated call IDs and paired result continuation, multiple calls, split-marker buffering, malformed/undeclared/duplicate/truncated calls, required-tool violations, reserved tokens, nesting/output bounds, and complete tool-history budget preservation. These are deterministic weight-free tests, not proof of real model quality or device support.

## Mac 制品

`gemma4-e2b-macos.download.json` 固定 Mac 非 AOT decoder 和 QAT 表。运行 `python3 scripts/download-gemma4.py --platform macos` 后，制品位于本目录的 `.local/Gemma4`。从仓库根执行 `HARNESS_TEST_GEMMA4=1 ./scripts/test-gemma4.sh` 使用该路径，也可传 `HARNESS_GEMMA4_ROOT` 指向其他制品根。iOS 资源继续使用生产 catalog。

## Decision 对照

在 Apple Silicon Mac 上下载上述制品后，从仓库根启动独立的 Gemma4Tests 实验。输出路径必须尚不存在。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
for mode in production inline-instruction; do
    for language in current-en current-zh-Hans; do
        GEMMA_DECISION_REPORT="/tmp/gemma-decision-${mode}-${language}.json" \
            GEMMA_DECISION_MODE="$mode" GEMMA_DECISION_LANGUAGE="$language" \
            swift test --filter gemmaDecisionModelEvaluation || exit
    done
done
```

实验从 M5 Apple/D3 归档取冻结的 54 条当前中英文处置用例，经过真实 Gemma4Chat 串行生成。production 复刻 App 的 system/user 请求。inline-instruction 将同一句输出格式要求移至 user 消息首部，用于检查 Gemma 的 system 过滤影响。各模式和语言均预热三次，逐条记录原始输出、完成原因、token 数和完整耗时。长跑可用 `GEMMA_DECISION_MODE=production` 或 `inline-instruction` 分组。语言用 `GEMMA_DECISION_LANGUAGE=current-en` 或 `current-zh-Hans` 指定。指定单一语言时，`GEMMA_DECISION_OFFSET` 可跳过该组已保存的开头样例，分段结果各写入新文件。单个数字且正常结束才计作有效分类。测试没有 Agent、UI 或工作流依赖。比较结果见 [Decision Mac 对照](../../docs/validation/Decision-Model-Mac-Comparison.md#gemma-4-e2b-decision-comparison)。
