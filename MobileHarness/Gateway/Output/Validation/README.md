# Resolved Output Authorization

## Summary

Rejects undeclared output kinds, paths, parameters and Channels before execution; validates startup coverage separately.

## Ownership and boundaries

OutputValidator consumes the descriptor of the trusted live source. BehaviorCoverage checks handler availability without constructing behavior or proving native effect correctness. Model aliases and domain value semantics are outside this directory.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 Envelope[Bound OutputEnvelope] --> Descriptor[Live source descriptor]
 Descriptor --> Validator[OutputValidator]
 Validator -->|Permitted resolved output| Routing
 Catalog[Host registration views] --> Coverage[BehaviorCoverage]
 Grants[Effective model and internal permissions] --> Coverage
```

## Checks and failure scope

Validate declared OutputKind, canonical path, required/optional argument names, string transport bounds, native enums and effective Channel allowlist. rejectedCall requires its corresponding Action/Tool output kind but has no executable path. Scheduling requires declared scheduling output; the scheduler separately checks balanced groups and task bounds.

OutputGateway additionally validates bound incarnation/session/task grant and communication policy. A validation/admission failure records an explicit outcome and cancels the owning Action tree before effects. Function allowlists do not grant OS permission or prove device safety.

BehaviorCoverage accepts at most 128 capability snapshots, resolves every model/internal Action in ActionRegistry and verifies every Tool handler path. Missing implementations fail startup. No queue/worker is owned here.

✅ Resolved authorization and effective registration coverage are implemented.

❌ Full JSON Schema and unified hardware permission policy are not implemented.

## Related design

[Parent design](../README.md)

## Skill/task-mode contract

✅ Maximum capabilities cannot authorize an unloaded model function. OutputGateway obtains the immutable current round catalog from the trusted Agent and checks Action/Tool permission there. Stale round scopes fail explicitly.


## Skill 函数目录

✅ OutputValidator 的 descriptor 由 Gateway 按调用来源选择：模型轮次使用冻结 Skill 目录，固定调用使用角色目录。保留参数和 Channel 校验，不额外要求业务权限白名单。

✅ Function coverage recognizes the exact Agent.Communication.send runtime-routed Action, which is now registered by Skill rather than synthesized afterward. Other functions still require native handlers; communication execution keeps target/contract checks in the existing Gateway path.
