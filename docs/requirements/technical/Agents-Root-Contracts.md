# Agents root contract placement

## Objective

Audit the loose files in `MobileHarness/Agents/` and keep only the module entry, composition and module-wide contracts at the root. Reusable mechanisms move to Support. No directory, target, dependency, queue, lifetime owner or runtime behavior is added or changed.

## Audit result

| Root file | Decision |
| --- | --- |
| `AgentContainer.swift`, `AgentRuntime.swift` | Stay: module root and composition root. |
| `AgentRepositories.swift`, `AgentHostBindings.swift`, `AgentGatewayPorts.swift`, `AgentFailure.swift` | Stay: injection, App-binding, Gateway and failure contracts shared by the whole module. |
| `AgentContracts.swift` | Stays as the composition table of role identities, communication schemas and concrete role registrations, but sheds reusable types. |

## Intended implementation

1. Move `AgentStateSnapshot` from `AgentContainer.swift` to a new root file `AgentState.swift`, next to `AgentFailure.swift`, so module-wide failure and state contracts are discoverable together.
2. Move `AgentLocalTool` and `AgentFunctionCatalog` from `AgentContracts.swift` to `Support/AgentConfigurations.swift`, which already owns validated declarations and function catalogs. Root composition still supplies the catalog.
3. Move the generic `AgentRequestImplementation` and `AgentEventImplementation` wrappers to `Support/Communication/AgentImplementations.swift`. The concrete per-role tables (`requestImplementations`, `eventImplementations`, `publicationImplementations`) and protocol validation remain in `AgentContracts` because they name concrete role types.
4. Update the Agents and Support/Communication READMEs, the overall file maps and the boundary checker's file references, and repair Xcode file references.

## Validation

Behavior is unchanged; run `./scripts/check.sh` and `./scripts/build-ios.sh` and record the actual outcomes and any toolchain limitation separately from real-model, UI and device acceptance.
