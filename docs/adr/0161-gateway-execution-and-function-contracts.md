# ADR0161 — Gateway execution and isolated function contracts

Accepted: 2026-10-06. Active Agent-Driven-App.md updated before code. Refines ADR0160; no new top-level directory.

Actions/Contracts compiles as FunctionContracts; business Actions depend on this protocol-neutral leaf only. FunctionInput/FunctionRequest expose canonical parameters, opaque context and an injected report sink, with no Channel or call protocol. Ordinary FunctionInvocation implements the input; Gateway scheduling adapters keep Channel outside it.

Gateway/Runtime compiles as ExecutionRuntime with common function registration/execution, bounded report storage and joined deadlines/cancellation. Gateway/Output registration/protocol adapters compile independently as CallRuntime without AgentCore; Gateway orchestrates them with AgentCore permission/owner/Signal contracts. App composition freezes one function catalog and supplies protocol bindings. Physical directory ownership does not introduce circular target dependencies.

✅ Preserve shared function constraints, permissions, bounded admission, resource fences, owner identity and feedback transport. ✅ Required check.sh passed: independent contract test, all507 integration and37 workflow tests, boundaries, formatting and metadata. ❌ Feature Signal migration, continuation and physical acceptance remain separate.

✅ Unsigned generic iOS device build and six packaged Agent configurations passed. ❌ Required simulator build stops because external CoreAIShared cannot resolve CoreAI; later build-ios.sh schemes were not attempted. No installation or physical acceptance is claimed.
