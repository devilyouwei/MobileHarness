# Function Contract Tests

Purpose: verify standard callable contracts independently of Gateway, execution SDKs and business modules. Design goals: concrete standard inputs, injected reporting and intrinsic metadata preservation.

✅ This target depends only on FunctionContracts. The fixture invokes one function with an ordinary FunctionInvocation and a test-owned bounded report sink.

❌ It grants no Agent permission or physical/model acceptance.

## Action timeout contract (2026-10-12)

✅ 验证基础默认 timeout、动态优先与异常不回退、无效静态值和预算上限，独立于 Gateway。
