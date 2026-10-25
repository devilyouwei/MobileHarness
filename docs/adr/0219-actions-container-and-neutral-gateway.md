# ADR 0219 — Actions root and neutral execution scheduling

## Decision

App constructs one ActionsContainer, GatewayContainer and AgentContainer per application scope. It configures after foundations, starts Actions → Gateway → Agents, and stops in reverse before releasing host bindings. Domains, modules and actions remain composable declarations/functions without peer containers or independent App registrations.

Agents owns role lifecycle, Skill/Task/decision authorization, communication permission and explicit scope revocation. Gateway owns neutral endpoint/envelope/scope validation, bounded scheduling, resource arbitration and result delivery. Actions owns canonical function registration, pure input preparation, resources/budget resolution, actual execution, output validation and native cleanup.

FunctionContracts has no project dependencies and contains neutral execution/catalog/host values. AgentCore depends only on FunctionContracts. Gateway imports only FunctionContracts. Agents imports Gateway public APIs and neutral contracts, without Actions/CallRuntime/ExecutionRuntime. Existing CallRuntime/ExecutionRuntime target identities now compile explicit source lists under Actions/Support. Agent-aware routing/authorization adapters compile in Agents/Support.

## Rationale and consequences

Gateway coordinates admitted work without understanding cognition or devices. Preparation produces a single-use catalog-revision credential, while Gateway acquires declared resources and Actions checks live permits/current business conditions. Capacity is reserved before asynchronous preparation; preparing, running, native cleanup and delivery all have owners and joined cancellation. Delivery retry cannot execute effects again.

A read-only descriptor catalog preserves one source for model resolution, Skill coverage and business validation without exposing handlers. Action and Tool protocol views use the canonical function store. App-bound Task/perception/maintenance ports allow asynchronous collaboration without storing upstream containers.

This supersedes the ownership and physical source placement in [ADR 0161](0161-gateway-execution-and-function-contracts.md). Its historical validation remains unchanged. Current contracts live in the [overall design](../../MobileHarness/README.md) and owning module READMEs; evidence lives in [Actions validation](../validation/Actions-Container.md).
