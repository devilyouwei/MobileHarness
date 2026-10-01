# ModelKit contract tests

Purpose: verify independent capability contracts and bounded inference sessions. Design goals: deterministic fixtures, explicit failure/cancellation and no business dependencies.

✅ SessionTests cover ordered completion, single consumers, explicit synchronous overflow, suspending emission with capacity one and cancellation of a blocked producer. Capability/media/resource tests verify validated independent SDK contracts.
❌ Real-model quality, latency and hardware behavior belong to adapter/device acceptance.

✅ Unbounded sessions retain 20,001 ordered events before consumption, including suspending yield; size validation and cancellation still apply. Existing bounded overflow tests remain.
