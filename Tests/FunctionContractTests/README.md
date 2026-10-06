# Function Contract Tests

Purpose: verify standard callable contracts independently of Gateway, execution SDKs and business modules. Design goals: concrete standard inputs, injected reporting and intrinsic metadata preservation.

✅ This target depends only on FunctionContracts. The fixture invokes one function with an ordinary FunctionInvocation and a test-owned bounded report sink.

❌ It grants no Agent permission or physical/model acceptance.
