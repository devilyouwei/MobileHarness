# Execution tests

## Actions execution chain coverage

ActionsContainerTests exercises pure preparation, credentials, both call protocols, resource permits, budgets, output validation, bounded retention and joined cleanup. ActionsContainerTests also covers the execution Shell lifecycle (pause/resume joining resource and action cleanup, repeated-stop failure retention, preparation capacity); GatewayContainerTests binds the actual ActionsContainer Shell to Gateway with neutral endpoint/scope and root lifecycle fixtures. ContainerExecutionFixtures supplies legacy scenario constructors in tests only; production has no registry-based Gateway API. Synthetic business/native substitutes do not establish real-device or real-model acceptance.

ContainerContextTests also verifies that an explicitly encoded owner snapshot remains a JSON object through collection and that read failures propagate, rather than encoding Data as a base64 string.

## 文件归属

- [ActionCompositionTests.swift](ActionCompositionTests.swift)
- [ChannelSchedulerTests.swift](ChannelSchedulerTests.swift)：Actions Shell调度契约。
- [ActionLifecycleTests.swift](ActionLifecycleTests.swift)
- [ActionObservationTests.swift](ActionObservationTests.swift)
- [ActionsContainerTests.swift](ActionsContainerTests.swift)
- [BehaviorAssemblyTests.swift](BehaviorAssemblyTests.swift)
